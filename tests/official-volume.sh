#!/usr/bin/env bash
# Reuse a cleanly stopped official-image volume without changing PGDATA.
#   tests/official-volume.sh <local-image> [podman|docker]
# Variables in bash -c scripts expand inside the container.
# shellcheck disable=SC2016
set -euo pipefail

image="${1:?Usage: tests/official-volume.sh <local-image> [podman|docker]}"
engine="${2:-podman}"
# postgres:18 (18.6, Debian trixie), checked 2026-10-31.
# https://github.com/docker-library/postgres/commit/e00e1bd34ec5c8a8e7ad89b273b3d42efaf6d5bc
official=docker.io/library/postgres:18@sha256:979bccfde35445db618c65107d27d08c6c21339d8dc3ad4c830c6633947be0e4
volume="psr-official-$$"
old="$volume-old"
new="$volume-new"
work="$(mktemp -d .official-volume.XXXXXX)"
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    "$engine" logs "$old" 2>&1 || true
    "$engine" logs "$new" 2>&1 || true
  fi
  "$engine" rm -f "$old" "$new" > /dev/null 2>&1 || true
  "$engine" volume rm "$volume" > /dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

wait_ready() {
  local _
  for _ in $(seq 90); do
    if "$engine" exec "$1" pg_isready -h 127.0.0.1 -q; then return; fi
    if [ "$("$engine" inspect "$1" --format '{{.State.Running}}')" != true ]; then break; fi
    sleep 1
  done
  echo "PostgreSQL did not start in $1" >&2
  return 1
}
psql() {
  "$engine" exec -i "$1" psql -h /run/postgresql -U postgres -d postgres -XAt -v ON_ERROR_STOP=1 "${@:2}"
}
cluster_files() {
  "$engine" exec "$1" bash -euc '
    cd "$PGDATA"
    sha256sum pg_hba.conf postgresql.conf postgresql.auto.conf
    stat -c "%a %u %g" .
  '
}

"$engine" volume create "$volume" > /dev/null
"$engine" run -d --name "$old" -e POSTGRES_HOST_AUTH_METHOD=trust \
  -v "$volume:/var/lib/postgresql" "$official" > /dev/null
wait_ready "$old"
psql "$old" <<'SQL'
CREATE TABLE official_volume (name text PRIMARY KEY, value integer NOT NULL);
INSERT INTO official_volume VALUES ('apple', 1), ('Zebra', 2), ('Ångström', 3), ('äpfel', 4);
SQL
expected="$(psql "$old" -c "SELECT string_agg(name || ':' || value, ',' ORDER BY name COLLATE \"C\") FROM official_volume")"
identifier="$(psql "$old" -c 'SELECT system_identifier FROM pg_control_system()')"
checksums="$(psql "$old" -c 'SHOW data_checksums')"
cluster_files "$old" > "$work/before"
"$engine" exec "$old" getconf GNU_LIBC_VERSION
"$engine" stop -t 60 "$old" > /dev/null
test "$("$engine" inspect "$old" --format '{{.State.ExitCode}}')" = 0

"$engine" run -d --name "$new" --user 999:999 --cap-drop=ALL \
  --security-opt=no-new-privileges -e POSTGRES_HOST_AUTH_METHOD=trust \
  -v "$volume:/var/lib/postgresql" "$image" > /dev/null
wait_ready "$new"
test "$(psql "$new" -c "SELECT string_agg(name || ':' || value, ',' ORDER BY name COLLATE \"C\") FROM official_volume")" = "$expected"
test "$(psql "$new" -c 'SELECT system_identifier FROM pg_control_system()')" = "$identifier"
test "$(psql "$new" -c 'SHOW data_checksums')" = "$checksums"
"$engine" exec "$new" bash -euc 'test "$PGDATA" = /var/lib/postgresql/18/docker; test ! -e "$PGDATA/.psr-managed"'
cluster_files "$new" > "$work/after"
cmp "$work/before" "$work/after"
"$engine" logs "$new" > "$work/log" 2>&1
if grep -Eq 'initdb:|initdb -|database system is initialized|running bootstrap script|performing post-bootstrap initialization|PostgreSQL init process complete' "$work/log"; then
  echo 'FAIL initdb ran on the imported volume' >&2
  exit 1
fi
echo 'ok   official volume reused: rows, cluster identity, checksums and configuration retained; no initdb'
if grep -Ei 'collation.*version.*mismatch|collation.*has version mismatch' "$work/log"; then
  echo 'collation-version-warning: yes'
else
  echo 'collation-version-warning: no'
fi
"$engine" stop -t 60 "$new" > /dev/null
test "$("$engine" inspect "$new" --format '{{.State.ExitCode}}')" = 0
