# Container entrypoint. Runs as a non-root user (uid 999 by default).
#
# On an empty PGDATA it initialises a cluster, creates POSTGRES_DB and runs any
# /docker-entrypoint-initdb.d/*.sql, *.sql.gz and *.sh once, like the official
# postgres image. New clusters use SSL with a self-signed certificate unless
# one is supplied; existing clusters keep their configuration. Arguments go to
# postgres after the defaults below, so `-c work_mem=64MB` style flags win.
# A command that is not postgres, such as `psql` or `bash`, runs as given.

if [ "${1:-}" = postgres ]; then
  shift
fi
case "${1:-}" in
  --help | -\? | --version | -V) exec postgres "$@" ;;
  "" | -*) ;;
  *) exec "$@" ;;
esac

: "${PGDATA:?PGDATA must be set}"
initdb_dir=/docker-entrypoint-initdb.d

# Do not hide an earlier volume behind a newly initialised cluster.
if [ "$PGDATA" = /var/lib/postgresql/18/docker ] &&
  [ ! -s "$PGDATA/PG_VERSION" ] && [ -e /var/lib/postgresql/18/data/PG_VERSION ]; then
  echo "Existing PSR cluster found at /var/lib/postgresql/18/data; refusing to initialise $PGDATA. Set PGDATA=/var/lib/postgresql/18/data to use it. No data has been moved or deleted." >&2
  exit 1
fi

enabled() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    0 | false | no | off | '') return 1 ;;
    *) echo "Invalid service switch: $1 (use true or false)" >&2; exit 1 ;;
  esac
}

# Read VAR from the file named by VAR_FILE, for Docker and Kubernetes secrets.
file_env() {
  local var="$1" file_var="$1_FILE"
  if [ -n "${!var:-}" ] && [ -n "${!file_var:-}" ]; then
    echo "Set $var or $file_var, not both" >&2
    exit 1
  fi
  if [ -n "${!file_var:-}" ]; then
    # A separate assignment, so a missing or unreadable file stops the start.
    local value
    value="$(< "${!file_var}")"
    export "$var"="$value"
    # Keep every PGRST_* input available to PostgREST, including this helper.
    if [ "$var" != PGRST_JWT_SECRET ]; then unset "$file_var"; fi
  fi
}
for name in POSTGRES_PASSWORD POSTGRES_USER POSTGRES_DB POSTGRES_INITDB_ARGS; do
  file_env "$name"
done
export POSTGRES_USER="${POSTGRES_USER:-postgres}"
export POSTGRES_DB="${POSTGRES_DB:-$POSTGRES_USER}"
auth="${POSTGRES_HOST_AUTH_METHOD:-scram-sha-256}"

if enabled "${POSTGREST_ENABLED-true}"; then
  file_env PGRST_JWT_SECRET
  if [[ ! -v PGRST_JWT_SECRET && ! -v PGRST_JWT_SECRET_FILE && -n "${POSTGRES_PASSWORD:-}" ]]; then
    # PostgREST validates the UTF-8 byte length, before serving requests.
    password_bytes="$(printf '%s' "$POSTGRES_PASSWORD" | wc -c)"
    if [ "$password_bytes" -ge 32 ]; then
      export PGRST_JWT_SECRET="$POSTGRES_PASSWORD"
    else
      echo "Warning: PostgREST JWT auth is off: POSTGRES_PASSWORD is shorter than 32 bytes; set PGRST_JWT_SECRET or use a password of at least 32 characters" >&2
    fi
  fi
fi

if enabled "${PGWEB_ENABLED-false}"; then
  file_env PGWEB_AUTH_PASS
  export PGWEB_AUTH_USER="${PGWEB_AUTH_USER:-$POSTGRES_USER}"
  export PGWEB_AUTH_PASS="${PGWEB_AUTH_PASS:-${POSTGRES_PASSWORD:-}}"
  if [ -z "$PGWEB_AUTH_PASS" ]; then
    echo "pgweb requires basic auth: set PGWEB_AUTH_PASS or POSTGRES_PASSWORD (or their _FILE forms)" >&2
    exit 1
  fi
fi

umask 077
runtime=/run/psr-services
mkdir -p "$runtime"
fresh=
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  fresh=1
  mkdir -p "$PGDATA"
  chmod 700 "$PGDATA"
elif [ -O "$PGDATA" ]; then
  # Like the official image, repair directory permissions on every start.
  # A volume remount with fsGroup can add group-write and setgid bits.
  chmod 00700 "$PGDATA" || :
fi
managed="$fresh"
if [ -f "$PGDATA/.psr-managed" ]; then managed=1; fi

generate_tls() {
  local dir
  # A unique runtime path cannot overwrite a cluster's certificates.
  dir="$(mktemp -d "$runtime/tls.XXXXXX")"
  cert="$dir/server.crt"
  key="$dir/server.key"
  openssl req -new -x509 -days 3650 -nodes -subj "/CN=${POSTGRES_SSL_CN:-postgres}" \
    -out "$cert" -keyout "$key" 2> /dev/null
  echo "Generated a self-signed certificate at $cert"
}

settings=()
if [ -n "${POSTGRES_SSL_CERT_FILE:-}" ]; then
  cert="$POSTGRES_SSL_CERT_FILE"
  key="${POSTGRES_SSL_KEY_FILE:?POSTGRES_SSL_KEY_FILE must be set with POSTGRES_SSL_CERT_FILE}"
  settings+=(-c ssl=on -c ssl_cert_file="$cert" -c ssl_key_file="$key")
elif [ -n "$managed" ]; then
  generate_tls
  settings+=(-c ssl=on -c ssl_cert_file="$cert" -c ssl_key_file="$key")
fi

if [ -n "$managed" ]; then
  settings+=(
    -c shared_preload_libraries="${POSTGRES_SHARED_PRELOAD_LIBRARIES:-pg_stat_statements,pg_cron,pg_ivm,pg_duckdb}"
    -c cron.database_name="${POSTGRES_CRON_DATABASE:-postgres}" -c cron.use_background_workers=on
    -c max_worker_processes=16
    -c duckdb.max_memory=256MB
    -c listen_addresses='*'
  )
else
  if [[ -v POSTGRES_SHARED_PRELOAD_LIBRARIES ]]; then
    settings+=(-c shared_preload_libraries="$POSTGRES_SHARED_PRELOAD_LIBRARIES")
  fi
  if [[ -v POSTGRES_CRON_DATABASE ]]; then
    settings+=(-c cron.database_name="$POSTGRES_CRON_DATABASE")
  fi
fi

if [ -n "$fresh" ]; then
  # No --locale: initdb takes LANG, which the image sets to en_US.UTF-8.
  initdb_args=(-D "$PGDATA" -U "$POSTGRES_USER" --encoding=UTF8
    --auth-local=trust --auth-host="$auth")
  if [ -n "${POSTGRES_PASSWORD:-}" ]; then
    pwfile="$(mktemp)"
    printf '%s' "$POSTGRES_PASSWORD" > "$pwfile"
    initdb_args+=(--pwfile="$pwfile")
  elif [ "$auth" != trust ]; then
    echo "POSTGRES_PASSWORD or POSTGRES_PASSWORD_FILE is required to initialise a new database, unless POSTGRES_HOST_AUTH_METHOD=trust" >&2
    exit 1
  fi
  if [ "$auth" = trust ]; then
    echo "Warning: POSTGRES_HOST_AUTH_METHOD=trust lets anyone who can reach port 5432 connect as any user, with no password" >&2
  fi
  if [ -n "${POSTGRES_INITDB_WALDIR:-}" ]; then
    initdb_args+=(--waldir="$POSTGRES_INITDB_WALDIR")
  fi
  # Word splitting is intended: POSTGRES_INITDB_ARGS holds several flags.
  # shellcheck disable=SC2086
  initdb "${initdb_args[@]}" ${POSTGRES_INITDB_ARGS:-}
  if [ -n "${pwfile:-}" ]; then rm -f "$pwfile"; fi
  echo "host all all all $auth" >> "$PGDATA/pg_hba.conf"
  # Retain these defaults on restarts without changing imported clusters.
  touch "$PGDATA/.psr-managed"
fi

# A function, so a sourced script's `set --` cannot replace the server's
# arguments.
run_init_scripts() {
  local f
  for f in "$initdb_dir"/*; do
    case "$f" in
      "$initdb_dir/*") ;;
      *.sh)
        echo "Running $f"
        # Like the official image: run executable scripts, source the rest.
        if [ -x "$f" ]; then
          "$f"
        else
          # shellcheck disable=SC1090
          . "$f"
        fi
        ;;
      *.sql) echo "Running $f"; "${psql[@]}" -f "$f" ;;
      *.sql.gz) echo "Running $f"; gzip -dc "$f" | "${psql[@]}" ;;
      *) echo "Ignoring $f" ;;
    esac
  done
}

if [ -n "$fresh" ]; then
  # Set up with the caller's settings, but on a known Unix socket only, so no
  # client sees a half-made database. Scripts inherit the PG* variables, so a
  # plain `psql` in an executable script reaches POSTGRES_DB. PGPASSWORD
  # covers POSTGRES_INITDB_ARGS that require a password on the socket.
  export PGHOST=/run/postgresql PGPORT="${PGPORT:-5432}" PGUSER="$POSTGRES_USER" PGDATABASE="$POSTGRES_DB"
  set_pgpassword=
  if [ -z "${PGPASSWORD:-}" ] && [ -n "${POSTGRES_PASSWORD:-}" ]; then
    export PGPASSWORD="$POSTGRES_PASSWORD"
    set_pgpassword=1
  fi
  pg_ctl -D "$PGDATA" -w start -o "$(printf '%q ' "${settings[@]}" "$@" \
    -c listen_addresses= -c unix_socket_directories="$PGHOST" -p "$PGPORT")"
  # initdb already made postgres, template0 and template1.
  exists="$(psql -v ON_ERROR_STOP=1 -X -qtA -d postgres -v db="$POSTGRES_DB" <<< "select 1 from pg_database where datname = :'db'")"
  if [ -z "$exists" ]; then
    psql -v ON_ERROR_STOP=1 -X -q -d postgres -v db="$POSTGRES_DB" <<< 'create database :"db"'
  fi
  psql=(psql -v ON_ERROR_STOP=1 -X -q -d "$POSTGRES_DB")
  run_init_scripts
  pg_ctl -D "$PGDATA" -m fast -w stop
  unset PGHOST PGUSER PGDATABASE
  if [ -n "$set_pgpassword" ]; then unset PGPASSWORD; fi
fi

# Bundled services connect through this socket; caller arguments still win.
server=(postgres -D "$PGDATA" "${settings[@]}" -c unix_socket_directories=/run/postgresql "$@")
pg_port="$("${server[@]}" -C port)"
cert="$("${server[@]}" -C ssl_cert_file)"
key="$("${server[@]}" -C ssl_key_file)"
# PostgreSQL resolves relative certificate paths against PGDATA.
[[ "$cert" = /* ]] || cert="$PGDATA/$cert"
[[ "$key" = /* ]] || key="$PGDATA/$key"

# This directory must permit execution: s6 executes its generated scripts.
services="$runtime/services"
mkdir -p "$runtime"
rm -rf "$services"
mkdir -p "$services/.s6-svscan"
service() {
  local name="$1" var attrs
  shift
  mkdir -p "$services/$name"
  # Secrets belong to their consumer, never the supervisor or command line.
  {
    # Every routed variable starts with PG. compgen would list exports, but the
    # image runs this script with a bash built without it, which fails silently.
    for var in ${!PG@}; do
      attrs="$(declare -p "$var")"
      attrs="${attrs#declare -}"
      [[ "${attrs%% *}" == *x* ]] || continue
      case "$var" in
        PGRST_*) [ "$name" = postgrest ] || continue ;;
        PGWEB_AUTH_USER | PGWEB_AUTH_PASS) [ "$name" = pgweb ] || continue ;;
        PGWEB_* | PGBOUNCER_*) continue ;;
        # Other PG* are libpq and server inputs, such as PGSERVICEFILE or
        # PGPASSFILE. PgBouncer reads none; it uses its config and the socket.
        *) [ "$name" != pgbouncer ] || continue ;;
      esac
      printf 'export %s=%q\n' "$var" "${!var}"
    done
  } > "$services/$name/environment"
  chmod 600 "$services/$name/environment"
  {
    printf '#!/bin/bash\nset -e\nsource ./environment\nexec '
    printf '%q ' "$@"
    printf '\n'
  } > "$services/$name/run"
  chmod 700 "$services/$name/run"
}

service postgres "${server[@]}"
echo INT > "$services/postgres/down-signal"
cat > "$services/postgres/finish" <<'EOF'
#!/bin/bash
# Exit 125 prevents even a brief restart while svscan takes the tree down.
if [ ! -e ../.s6-svscan/stopping ]; then
  status="$1"
  if [ "$status" -eq 256 ]; then status=$((128 + $2)); fi
  if [ "$status" -eq 0 ]; then status=1; fi
  echo "$status" > ../.s6-svscan/exitcode
  s6-svscanctl -t ..
fi
exit 125
EOF
cat > "$services/.s6-svscan/SIGTERM" <<'EOF'
#!/bin/bash
# Mark an intentional stop before postgres's finish script runs.
touch .s6-svscan/stopping
exec s6-svscanctl -t .
EOF
ln -s SIGTERM "$services/.s6-svscan/SIGINT"
cat > "$services/.s6-svscan/finish" <<'EOF'
#!/bin/bash
status=0
if [ -f .s6-svscan/exitcode ]; then read -r status < .s6-svscan/exitcode; fi
exit "$status"
EOF
chmod 700 "$services/postgres/finish" "$services/.s6-svscan/SIGTERM" "$services/.s6-svscan/finish"

if enabled "${PGBOUNCER_ENABLED-true}"; then
  if [ "$("${server[@]}" -C ssl)" = off ]; then
    generate_tls
  fi
  case "$auth" in
    scram-sha-256 | md5 | trust) ;;
    *) echo "PgBouncer supports POSTGRES_HOST_AUTH_METHOD=scram-sha-256, md5 or trust; disable it for other methods" >&2; exit 1 ;;
  esac
  # PgBouncer's user lists cannot represent names containing commas or spaces.
  if [[ "$POSTGRES_USER" = *[[:space:],]* ]]; then
    echo "PgBouncer requires POSTGRES_USER without whitespace or commas; set PGBOUNCER_ENABLED=false for this role name" >&2
    exit 1
  fi
  # INI values are literal lines, with leading/trailing whitespace stripped.
  for value in "$cert" "$key"; do
    if [[ "$value" = *$'\n'* || "$value" = *$'\r'* || "$value" = [[:space:]]* || "$value" = *[[:space:]] ]]; then
      echo "PgBouncer certificate paths cannot contain newlines or surrounding whitespace" >&2
      exit 1
    fi
  done
  for name in PGBOUNCER_PORT PGBOUNCER_DEFAULT_POOL_SIZE PGBOUNCER_MAX_CLIENT_CONN; do
    value="${!name:-}"
    if [[ -n "$value" && ( ! "$value" =~ ^[0-9]+$ || "$value" =~ ^0+$ ) ]]; then
      echo "$name must be a positive integer" >&2
      exit 1
    fi
  done
  pool_mode="${PGBOUNCER_POOL_MODE:-transaction}"
  case "$pool_mode" in
    transaction | session | statement) ;;
    *) echo "PGBOUNCER_POOL_MODE must be transaction, session or statement" >&2; exit 1 ;;
  esac
  cat > "$runtime/pgbouncer.ini" <<EOF
[databases]
* = host=/run/postgresql port=$pg_port

[pgbouncer]
listen_addr = *
listen_port = ${PGBOUNCER_PORT:-6432}
unix_socket_dir =
auth_type = $auth
auth_user = $POSTGRES_USER
auth_dbname = postgres
auth_query = SELECT rolname, CASE WHEN rolvaliduntil < now() THEN NULL ELSE rolpassword END FROM pg_authid WHERE rolname=\$1 AND rolcanlogin
pool_mode = $pool_mode
max_prepared_statements = 100
default_pool_size = ${PGBOUNCER_DEFAULT_POOL_SIZE:-20}
max_client_conn = ${PGBOUNCER_MAX_CLIENT_CONN:-100}
client_tls_sslmode = allow
client_tls_cert_file = $cert
client_tls_key_file = $key
# Without a CA file, libtls looks for a system bundle the image does not have.
client_tls_ca_file = $SSL_CERT_FILE
admin_users = $POSTGRES_USER
stats_users = $POSTGRES_USER
EOF
  chmod 600 "$runtime/pgbouncer.ini"
  service pgbouncer pgbouncer "$runtime/pgbouncer.ini"
  # Since 1.23, PgBouncer's TERM waits for clients, including idle consoles.
  echo QUIT > "$services/pgbouncer/down-signal"
fi

# libpq keyword values escape quotes and backslashes, unlike shell arguments.
conn_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf "'%s'" "$value"
}
if enabled "${POSTGREST_ENABLED-true}"; then
  PGRST_DB_URI="${PGRST_DB_URI-host=/run/postgresql port=$pg_port user=$(conn_value "$POSTGRES_USER") dbname=$(conn_value "$POSTGRES_DB")}"
  export PGRST_DB_URI
  export PGRST_DB_SCHEMAS="${PGRST_DB_SCHEMAS-public}"
  export PGRST_SERVER_PORT="${PGRST_SERVER_PORT-3000}"
  service postgrest postgrest
fi

if enabled "${PGWEB_ENABLED-false}"; then
  # pgweb reads basic-auth credentials from the environment, not argv.
  service pgweb env -u PGWEB_LOCK_SESSION -u LOCK_SESSION pgweb \
    --bind=0.0.0.0 --listen="${PGWEB_PORT:-8081}" --sessions --skip-open \
    --bookmarks-dir="$runtime/bookmarks" --queries-dir="$runtime/queries"
fi

# PostgreSQL's init variables are no longer needed; restore only each service's
# saved environment after exec has removed these values from /proc/1/environ.
for name in ${!POSTGRES_@} ${!PG@} AUTH_USER AUTH_PASS; do
  unset "$name"
done
exec s6-svscan "$services"
