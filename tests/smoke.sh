#!/usr/bin/env bash
# Smoke-test a running container of this image: SSL is on, the preload set is
# loaded, the cron scheduler runs jobs, init scripts ran in order, and every bundled
# extension can be created. Start the container with POSTGRES_DB=app and
# tests/initdb mounted at /docker-entrypoint-initdb.d.
#   tests/smoke.sh <container> [docker|podman]
# Variables in bash -c scripts expand inside the container.
# shellcheck disable=SC2016
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

# PgBouncer can listen before PostgreSQL is ready for its auth_query.
for _ in $(seq 60); do
  if "$engine" exec "$container" bash -c 'PGPASSWORD=$POSTGRES_PASSWORD psql "host=127.0.0.1 port=${PGBOUNCER_PORT:-6432} user=postgres dbname=postgres connect_timeout=2" -XAtc "select 1"' > /dev/null 2>&1; then break; fi
  sleep 1
done
pool_psql() {
  "$engine" exec "$container" bash -c 'export PGPASSWORD=$POSTGRES_PASSWORD; exec psql "host=127.0.0.1 port=${PGBOUNCER_PORT:-6432} user=postgres dbname=$1 sslmode=$2 connect_timeout=5" -XAt -v ON_ERROR_STOP=1 -c "$3"' bash "$@"
}
check pgbouncer-tcp "$(pool_psql app disable 'select current_database()')" app
# pg_stat_ssl describes the socket backend, so require TLS on the client hop.
check pgbouncer-ssl "$(pool_psql postgres require 'select 42')" 42
pools="$(pool_psql pgbouncer require 'show pools')"
check pgbouncer-admin "$(grep -c '^postgres|postgres|' <<< "$pools")" 1
if "$engine" exec "$container" bash -c 'PGPASSWORD=deliberately-wrong psql "host=127.0.0.1 port=${PGBOUNCER_PORT:-6432} user=postgres dbname=postgres connect_timeout=5" -XAtc "select 1"' > /dev/null 2>&1; then
  check pgbouncer-rejects-password accepted rejected
else
  check pgbouncer-rejects-password rejected rejected
fi
# A role created after startup must work without a generated userlist.
psql -c "create role smoke_pool login password 'pool-only'"
check pgbouncer-role "$("$engine" exec "$container" bash -c 'PGPASSWORD=pool-only psql "host=127.0.0.1 port=${PGBOUNCER_PORT:-6432} user=smoke_pool dbname=app sslmode=require connect_timeout=5" -XAtc "select current_user"')" smoke_pool
psql -c 'drop role smoke_pool'

http_status() {
  "$engine" exec "$container" bash -c '
    exec 3<>/dev/tcp/127.0.0.1/"$1"
    printf "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n" >&3
    read -r -t 5 status <&3
    printf "%s\n" "$status"
  ' bash "$1" 2> /dev/null
}
pgrst_port="$("$engine" exec "$container" bash -c 'printf "%s" "${PGRST_SERVER_PORT:-3000}"')"
status=
for _ in $(seq 60); do
  status="$(http_status "$pgrst_port" || true)"
  case "$status" in *' 401 '* | *' 403 '*) break ;; esac
  sleep 1
done
case "$status" in
  *' 401 '* | *' 403 '*) check postgrest-anonymous refused refused ;;
  *) check postgrest-anonymous "$status" 'HTTP 401 or 403' ;;
esac
pgweb_enabled="$("$engine" exec "$container" bash -c 'printf "%s" "${PGWEB_ENABLED:-false}"')"
case "${pgweb_enabled,,}" in
  1 | true | yes | on)
    pgweb_port="$("$engine" exec "$container" bash -c 'printf "%s" "${PGWEB_PORT:-8081}"')"
    status=
    for _ in $(seq 30); do
      status="$(http_status "$pgweb_port" || true)"
      case "$status" in *' 200 '* | *' 401 '*) break ;; esac
      sleep 1
    done
    case "$status" in
      *' 200 '* | *' 401 '*) check pgweb-http answered answered ;;
      *) check pgweb-http "$status" 'HTTP 200 or 401' ;;
    esac
    ;;
esac

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

if out="$(psql -d smoke -c 'do $$ plpy.notice(1) $$ language plpython3u' 2>&1)"; then
  check plpython3u "$(grep -c NOTICE <<< "$out")" 1
else
  check plpython3u "$out" 'one NOTICE and success'
fi
check pljs "$(psql -d smoke -c 'create function js_double(n int) returns int language pljs as $$ return n * 2 $$' -c 'select js_double(21)')" 42
check pg_duckdb "$(psql -d smoke -c 'select * from duckdb.query($$ select 40 + 2 as answer $$)')" 42
check vector "$(psql -d smoke -c "select '[1,2,3]'::vector <-> '[1,2,4]'::vector")" 1
check postgis "$(psql -d smoke -c 'select st_astext(st_point(1, 2))')" 'POINT(1 2)'

exit "$fail"
