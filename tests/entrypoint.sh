#!/usr/bin/env bash
# Exercise credential routing without PostgreSQL, s6 or a container runtime.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "$repo/.entrypoint-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
sed "s|runtime=/run/psr-services|runtime=$work/runtime|" "$repo/entrypoint.sh" > "$work/entrypoint.sh"
cat > "$work/bin/postgres" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${*: -2:1}" = -C ]]; then
  case "${*: -1}" in
    port) echo 5432 ;;
    ssl_cert_file) echo "$TEST_DATA/server.crt" ;;
    ssl_key_file) echo "$TEST_DATA/server.key" ;;
  esac
else
  env -0 > "$TEST_RESULTS/postgres"
fi
EOF
cat > "$work/bin/s6-svscan" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
env -0 > "$TEST_RESULTS/s6"
for name in postgres pgbouncer postgrest pgweb; do
  if [ -d "$1/$name" ]; then (cd "$1/$name"; bash ./run); fi
done
EOF
cat > "$work/bin/consumer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
env -0 > "$TEST_RESULTS/${0##*/}"
printf '%s\0' "$@" > "$TEST_RESULTS/${0##*/}.argv"
EOF
chmod +x "$work/bin/"*
for name in pgbouncer postgrest pgweb; do ln -s consumer "$work/bin/$name"; done

boot() {
  rm -rf "$work/data" "$work/results" "$work/runtime"
  mkdir -p "$work/data" "$work/results"
  printf '18\n' > "$work/data/PG_VERSION"
  printf 'stub\n' > "$work/data/server.crt"
  printf 'stub\n' > "$work/data/server.key"
  env -i PATH="$work/bin:$PATH" PGDATA="$work/data" TEST_DATA="$work/data" \
    TEST_RESULTS="$work/results" SSL_CERT_FILE=/unused "$@" \
    "${ENTRYPOINT_BASH:-bash}" -euo pipefail "$work/entrypoint.sh" > "$work/stdout" 2> "$work/stderr"
}
has() {
  local entry
  [ -f "$work/results/$1" ] || return 1
  while IFS= read -r -d '' entry; do
    if [ "${entry%%=*}" = "$2" ]; then
      [ "$entry" = "$2=$3" ]
      return
    fi
  done < "$work/results/$1"
  return 1
}
absent() {
  local entry
  while IFS= read -r -d '' entry; do
    [ "${entry%%=*}" != "$2" ] || return 1
  done < "$work/results/$1"
}
isolated() {
  local service
  for service in postgres pgbouncer postgrest pgweb s6; do
    [ -f "$work/results/$service" ] || continue
    absent "$service" POSTGRES_PASSWORD
    absent "$service" POSTGRES_PASSWORD_FILE
    if [ "$service" != postgrest ]; then
      absent "$service" PGRST_JWT_SECRET
      absent "$service" PGRST_JWT_SECRET_FILE
      absent "$service" PGRST_DB_URI
    fi
    if [ "$service" != pgweb ]; then absent "$service" PGWEB_AUTH_PASS; fi
  done
}

password=01234567890123456789012345678901
boot POSTGRES_PASSWORD="$password" PGWEB_ENABLED=1
has postgrest PGRST_JWT_SECRET "$password"
has pgweb PGWEB_AUTH_USER postgres
has pgweb PGWEB_AUTH_PASS "$password"
isolated
test "$(stat -c %a "$work/runtime/services/pgweb/environment")" = 600
echo 'ok   derived credentials and service environments'

boot POSTGRES_PASSWORD=0123456789012345678901234567890 PGWEB_ENABLED=1
absent postgrest PGRST_JWT_SECRET
grep -qF 'PostgREST JWT auth is off' "$work/stderr"
has pgweb PGWEB_AUTH_PASS 0123456789012345678901234567890
echo 'ok   31-byte password warns without blocking startup'

boot POSTGRES_PASSWORD=éééééééééééééééé
has postgrest PGRST_JWT_SECRET éééééééééééééééé
echo 'ok   the JWT minimum counts UTF-8 bytes'

boot POSTGRES_HOST_AUTH_METHOD=trust
absent postgrest PGRST_JWT_SECRET
test ! -s "$work/stderr"
echo 'ok   existing cluster without a password leaves JWT unset'

if boot PGWEB_ENABLED=1 POSTGRES_HOST_AUTH_METHOD=trust; then exit 1; fi
grep -qF 'set PGWEB_AUTH_PASS or POSTGRES_PASSWORD' "$work/stderr"
echo 'ok   pgweb without a password fails closed'

explicit=$'separate key with quotes '\'' and " dollars $ and\nnewlines'
boot POSTGRES_PASSWORD="$password" POSTGRES_USER=owner PGWEB_ENABLED=1 \
  PGWEB_AUTH_USER=web PGWEB_AUTH_PASS="$explicit" PGRST_JWT_SECRET="$explicit" \
  PGRST_APP_SETTINGS_CUSTOM="$explicit" PGRST_JWT_AUD=example \
  PGRST_DB_ANON_ROLE=anon PGRST_JWT_ROLE_CLAIM_KEY=.custom PGRST_DB_PRE_REQUEST=public.check \
  PGRST_JWT_SECRET_IS_BASE64=false PGRST_FUTURE_SETTING=
has postgrest PGRST_JWT_SECRET "$explicit"
has postgrest PGRST_APP_SETTINGS_CUSTOM "$explicit"
has postgrest PGRST_FUTURE_SETTING ''
has postgrest PGRST_DB_ANON_ROLE anon
has postgrest PGRST_JWT_AUD example
has postgrest PGRST_JWT_ROLE_CLAIM_KEY .custom
has postgrest PGRST_DB_PRE_REQUEST public.check
has postgrest PGRST_JWT_SECRET_IS_BASE64 false
has pgweb PGWEB_AUTH_USER web
has pgweb PGWEB_AUTH_PASS "$explicit"
isolated
echo 'ok   explicit credentials and arbitrary PGRST inputs round-trip'

printf '%s\n' "$password" > "$work/password"
printf '%s\n' "$explicit" > "$work/jwt"
printf 'web-password\n' > "$work/web"
boot POSTGRES_PASSWORD_FILE="$work/password" PGWEB_ENABLED=1 POSTGRES_USER=owner
has postgrest PGRST_JWT_SECRET "$password"
has pgweb PGWEB_AUTH_USER owner
has pgweb PGWEB_AUTH_PASS "$password"
isolated
boot POSTGRES_PASSWORD_FILE="$work/password" PGWEB_ENABLED=1 \
  PGRST_JWT_SECRET_FILE="$work/jwt" PGWEB_AUTH_PASS_FILE="$work/web"
has postgrest PGRST_JWT_SECRET "$explicit"
has postgrest PGRST_JWT_SECRET_FILE "$work/jwt"
has pgweb PGWEB_AUTH_PASS web-password
isolated
boot PGWEB_ENABLED=1 PGWEB_AUTH_PASS_FILE="$work/web" POSTGRES_HOST_AUTH_METHOD=trust
has pgweb PGWEB_AUTH_PASS web-password
absent postgrest PGRST_JWT_SECRET
echo 'ok   secret files expand before defaults and respect overrides'

boot POSTGRES_PASSWORD="$password" PGRST_JWT_SECRET=
has postgrest PGRST_JWT_SECRET ''
if boot POSTGRES_PASSWORD="$password" PGRST_JWT_SECRET="$explicit" PGRST_JWT_SECRET_FILE="$work/jwt"; then exit 1; fi
grep -qF 'not both' "$work/stderr"
echo 'ok   explicit empty JWT is preserved and conflicting forms fail'

boot POSTGRES_PASSWORD="$password" POSTGREST_ENABLED=false PGWEB_ENABLED=false \
  PGRST_JWT_SECRET_FILE=/missing PGWEB_AUTH_PASS_FILE=/missing PGRST_DB_URI=secret
test ! -d "$work/runtime/services/postgrest"
test ! -d "$work/runtime/services/pgweb"
isolated
echo 'ok   disabled services do not read or distribute their secrets'

# Run the workflow's audit itself with failing and successful Nix queries.
audit="$(sed -n '/^          closure=/,/^          if grep systemd/p' "$repo/.github/workflows/image.yml")"
test -n "$audit"
cat > "$work/bin/nix" <<'EOF'
#!/usr/bin/env bash
case "$TEST_AUDIT" in
  error) exit 7 ;;
  systemd) echo /nix/store/systemd ;;
  clean) echo /nix/store/s6 ;;
esac
EOF
chmod +x "$work/bin/nix"
for mode in error systemd; do
  if PATH="$work/bin:$PATH" TEST_AUDIT="$mode" bash -euo pipefail -c "$audit" > /dev/null; then exit 1; fi
done
PATH="$work/bin:$PATH" TEST_AUDIT=clean bash -euo pipefail -c "$audit"
echo 'ok   closure audit rejects query failures and systemd'
