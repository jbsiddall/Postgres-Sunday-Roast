# Container entrypoint. Runs as a non-root user (uid 999 by default).
#
# On an empty PGDATA it initialises a cluster, creates POSTGRES_DB and runs any
# /docker-entrypoint-initdb.d/*.sql, *.sql.gz and *.sh once, like the official
# postgres image. It then starts PostgreSQL with SSL on, generating a
# self-signed certificate unless one is supplied. Extra arguments are passed to
# postgres after the defaults below, so `-c work_mem=64MB` style flags win.

: "${PGDATA:?PGDATA must be set}"
user="${POSTGRES_USER:-postgres}"
db="${POSTGRES_DB:-$user}"
initdb_dir=/docker-entrypoint-initdb.d

umask 077
mkdir -p "$PGDATA"
chmod 700 "$PGDATA"

if [ -n "${POSTGRES_SSL_CERT_FILE:-}" ]; then
  cert="$POSTGRES_SSL_CERT_FILE"
  key="${POSTGRES_SSL_KEY_FILE:?POSTGRES_SSL_KEY_FILE must be set with POSTGRES_SSL_CERT_FILE}"
else
  cert="$PGDATA/server.crt"
  key="$PGDATA/server.key"
fi

settings=(
  -c ssl=on -c ssl_cert_file="$cert" -c ssl_key_file="$key"
  -c shared_preload_libraries="${POSTGRES_SHARED_PRELOAD_LIBRARIES:-pg_stat_statements,pg_cron,pg_ivm,pg_duckdb}"
  -c cron.database_name="${POSTGRES_CRON_DATABASE:-postgres}" -c cron.use_background_workers=on
  -c max_worker_processes=16
  -c duckdb.max_memory=256MB
)

fresh=
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required to initialise a new database}"
  pwfile="$(mktemp)"
  printf '%s' "$POSTGRES_PASSWORD" > "$pwfile"
  # Word splitting is intended: POSTGRES_INITDB_ARGS holds several flags.
  # shellcheck disable=SC2086
  initdb -D "$PGDATA" -U "$user" --pwfile="$pwfile" --encoding=UTF8 --locale=en_US.UTF-8 \
    --auth-local=trust --auth-host=scram-sha-256 ${POSTGRES_INITDB_ARGS:-}
  rm -f "$pwfile"
  echo 'host all all all scram-sha-256' >> "$PGDATA/pg_hba.conf"
  fresh=1
fi

if [ ! -s "$key" ]; then
  openssl req -new -x509 -days 3650 -nodes -subj "/CN=${POSTGRES_SSL_CN:-postgres}" \
    -out "$cert" -keyout "$key" 2> /dev/null
  echo "Generated a self-signed certificate at $cert"
fi

if [ -n "$fresh" ]; then
  # Set up on the Unix socket only, so no client sees a half-made database.
  pg_ctl -D "$PGDATA" -w -o "$(printf '%q ' "${settings[@]}") -c listen_addresses=''" start
  psql=(psql -v ON_ERROR_STOP=1 -X -q -h /run/postgresql -U "$user")
  if [ "$db" != postgres ]; then
    "${psql[@]}" -d postgres -c "create database \"$db\""
  fi
  for f in "$initdb_dir"/*; do
    case "$f" in
      "$initdb_dir/*") ;;
      *.sh) echo "Running $f"; # shellcheck disable=SC1090
        . "$f" ;;
      *.sql) echo "Running $f"; "${psql[@]}" -d "$db" -f "$f" ;;
      *.sql.gz) echo "Running $f"; gzip -dc "$f" | "${psql[@]}" -d "$db" ;;
      *) echo "Ignoring $f" ;;
    esac
  done
  pg_ctl -D "$PGDATA" -m fast -w stop
fi

exec postgres -D "$PGDATA" "${settings[@]}" -c listen_addresses='*' "$@"
