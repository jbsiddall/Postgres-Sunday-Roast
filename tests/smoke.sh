#!/usr/bin/env bash
# Smoke-test a running container of this image: SSL is on, the preload set is
# loaded, the cron scheduler runs jobs, init scripts ran in order, and every bundled
# extension can be created. Start the container with POSTGRES_DB=app and
# tests/initdb mounted at /docker-entrypoint-initdb.d.
#   tests/smoke.sh <container> [docker|podman]
set -euo pipefail

container="$1"
engine="${2:-docker}"
psql() { "$engine" exec -i "$container" psql -h /run/postgresql -U postgres -X -q -At -v ON_ERROR_STOP=1 "$@"; }

# pg_isready also answers during init, when only the Unix socket is up, so
# wait for the final server on TCP.
for _ in $(seq 90); do
  "$engine" exec "$container" pg_isready -h 127.0.0.1 -q && break
  sleep 1
done

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi; }

check ssl "$(psql -c 'show ssl')" on
check ssl-over-tcp "$("$engine" exec "$container" bash -c 'PGPASSWORD=$POSTGRES_PASSWORD psql "host=127.0.0.1 sslmode=require user=postgres dbname=postgres" -XAtc "select ssl from pg_stat_ssl where pid = pg_backend_pid()"')" t
check preload "$(psql -c 'show shared_preload_libraries')" pg_stat_statements,pg_cron,pg_ivm,pg_duckdb
check collate "$(psql -c "select datcollate from pg_database where datname = 'postgres'")" en_US.UTF-8
check initdb-sql "$(psql -d app -c 'select count(*) from items')" 2
check initdb-sh "$(psql -d app -c "select has_table_privilege('reader', 'items', 'select')")" t
check initdb-order "$(psql -d app -c "select string_agg(step || ':' || by_user, ',' order by ctid) from init_log")" \
  sourced:postgres,executed:postgres,after:postgres

# The scheduler must run a job, not just accept one.
psql -c 'create extension if not exists pg_cron' -c 'drop table if exists cron_smoke' -c 'create table cron_smoke (at timestamptz)'
psql -c "select cron.schedule('smoke', '1 seconds', 'insert into cron_smoke values (now())')" > /dev/null
ran=f
for _ in $(seq 30); do
  ran="$(psql -c 'select count(*) > 0 from cron_smoke')"
  [ "$ran" = t ] && break
  sleep 1
done
psql -c "select cron.unschedule('smoke')" -c 'drop table cron_smoke' > /dev/null
check cron-runs "$ran" t

psql -c 'drop database if exists smoke' -c 'create database smoke'
# pg_cron can only live in cron.database_name, which is checked above. Fetch
# the list first, so a failed query fails the test instead of skipping the loop.
exts="$(psql -d smoke -c "select name from pg_available_extensions where name not in ('pg_cron') order by 1")"
check extension-count "$(($(wc -l <<< "$exts") >= 90))" 1
for ext in $exts; do
  if out="$(psql -d smoke -c "create extension if not exists \"$ext\" cascade" 2>&1)"; then
    echo "ok   extension $ext"
  else
    echo "FAIL extension $ext: $(echo "$out" | grep -m1 -E 'ERROR|FATAL')"
    fail=1
  fi
done

if out="$(psql -d smoke -c 'do $ plpy.notice(1) $ language plpython3u' 2>&1)"; then
  check plpython3u "$(grep -c NOTICE <<< "$out")" 1
else
  check plpython3u "$out" 'one NOTICE and success'
fi
check pljs "$(psql -d smoke -c 'create function js_double(n int) returns int language pljs as $$ return n * 2 $$' -c 'select js_double(21)')" 42
check pg_duckdb "$(psql -d smoke -c 'select * from duckdb.query($$ select 40 + 2 as answer $$)')" 42
check vector "$(psql -d smoke -c "select '[1,2,3]'::vector <-> '[1,2,4]'::vector")" 1
check postgis "$(psql -d smoke -c 'select st_astext(st_point(1, 2))')" 'POINT(1 2)'

exit "$fail"
