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
    printf "GET / HTTP/1.0\r\nHost: localhost\r\n" >&3
    if [ -n "${2:-}" ]; then printf "Authorization: %s\r\n" "$2" >&3; fi
    printf "\r\n" >&3
    read -r -t 5 status <&3
    printf "%s\n" "$status"
  ' bash "$1" "${2:-}" 2> /dev/null
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

# Mint with the database password, not the derived service environment.
if "$engine" exec "$container" bash -c 'command -v openssl' > /dev/null; then
  token="$("$engine" exec "$container" bash -euo pipefail -c '
    password=${POSTGRES_PASSWORD:-}
    if [ -n "${POSTGRES_PASSWORD_FILE:-}" ]; then password=$(< "$POSTGRES_PASSWORD_FILE"); fi
    if [[ -v PGRST_JWT_SECRET || -v PGRST_JWT_SECRET_FILE ]] || [ "$(printf %s "$password" | wc -c)" -lt 32 ]; then exit; fi
    b64url() { openssl base64 -A | tr "+/" "-_" | tr -d "="; }
    header=$(printf %s '\''{"alg":"HS256","typ":"JWT"}'\'' | b64url)
    # Smoke fixtures use the default postgres superuser.
    payload=$(printf '\''{"role":"postgres","exp":%s}'\'' "$(( $(date +%s) + 60 ))" | b64url)
    input=$header.$payload
    # Build HMAC pads in bash so even the test keeps secrets out of argv.
    key_stream() {
      if [ "$(printf %s "$password" | wc -c)" -gt 64 ]; then
        printf %s "$password" | openssl dgst -sha256 -binary
      else
        printf %s "$password"
      fi
    }
    # Word splitting is intended: od emits decimal bytes.
    # shellcheck disable=SC2207
    key_bytes=( $(key_stream | od -An -v -tu1) )
    pad() {
      local i oct
      for ((i=0; i<64; i++)); do
        printf -v oct "%03o" "$(( ${key_bytes[i]:-0} ^ $1 ))"
        printf "%b" "\\$oct"
      done
    }
    signature=$({ pad 92; { pad 54; printf %s "$input"; } | openssl dgst -sha256 -binary; } | openssl dgst -sha256 -binary | b64url)
    printf "%s.%s" "$input" "$signature"
  ')"
  if [ -n "$token" ]; then
    case "$(http_status "$pgrst_port" "Bearer $token")" in
      *' 200 '*) check postgrest-password-jwt accepted accepted ;;
      *) check postgrest-password-jwt refused accepted ;;
    esac
  else
    echo 'skip postgrest-password-jwt: requires the default secret and a password of at least 32 bytes'
    if "$engine" exec "$container" bash -euo pipefail -c '
      [[ ! -v PGRST_JWT_SECRET && ! -v PGRST_JWT_SECRET_FILE ]] || exit 1
      password=${POSTGRES_PASSWORD:-}
      if [ -n "${POSTGRES_PASSWORD_FILE:-}" ]; then password=$(< "$POSTGRES_PASSWORD_FILE"); fi
      [ -n "$password" ] && [ "$(printf %s "$password" | wc -c)" -lt 32 ]
    '; then
      logs="$("$engine" logs "$container" 2>&1)"
      if grep -qF 'PostgREST JWT auth is off' <<< "$logs"; then
        check postgrest-short-password-warning logged logged
      else
        check postgrest-short-password-warning missing logged
      fi
    fi
  fi
else
  echo 'skip postgrest-password-jwt: openssl is unavailable'
fi

# Read the actual exec environments, not docker exec's original container env.
if "$engine" exec "$container" bash -euo pipefail -c '
  found=0
  for proc in /proc/[0-9]*; do
    [ -r "$proc/comm" ] || continue
    read -r name < "$proc/comm" || continue
    case "$name" in postgres | pgbouncer | postgrest | pgweb | s6-svscan) ;; *) continue ;; esac
    if [ "$name" = pgbouncer ]; then found=1; fi
    while IFS= read -r -d "" entry; do
      var=${entry%%=*}
      case "$var" in
        POSTGRES_PASSWORD | POSTGRES_PASSWORD_FILE) exit 1 ;;
        PGRST_*) [ "$name" = postgrest ] || exit 1 ;;
        PGWEB_AUTH_*) [ "$name" = pgweb ] || exit 1 ;;
      esac
    done < "$proc/environ"
  done
  [ "$found" = 1 ]
'; then
  check service-secret-environments isolated isolated
else
  check service-secret-environments leaked isolated
fi

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
      *' 401 '*) check pgweb-basic-auth required required ;;
      *) check pgweb-basic-auth "$status" 'HTTP 401' ;;
    esac
    basic="$("$engine" exec "$container" bash -euo pipefail -c '
      password=${POSTGRES_PASSWORD:-}
      if [ -n "${POSTGRES_PASSWORD_FILE:-}" ]; then password=$(< "$POSTGRES_PASSWORD_FILE"); fi
      password=${PGWEB_AUTH_PASS:-$password}
      if [ -n "${PGWEB_AUTH_PASS_FILE:-}" ]; then password=$(< "$PGWEB_AUTH_PASS_FILE"); fi
      printf "%s:%s" "${PGWEB_AUTH_USER:-${POSTGRES_USER:-postgres}}" "$password" | base64 -w0
    ')"
    case "$(http_status "$pgweb_port" "Basic $basic")" in
      *' 200 '*) check pgweb-login accepted accepted ;;
      *) check pgweb-login refused accepted ;;
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
