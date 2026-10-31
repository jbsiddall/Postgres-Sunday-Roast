# Implementation decisions

## Only extensions that work without preload

The image includes an extension only if `CREATE EXTENSION` succeeds with the
default `shared_preload_libraries`. Rejected: also bundling `pg_net`,
`pg_squeeze`, `pg_textsearch`, `pgaudit` and `timescaledb`, which refuse
`CREATE EXTENSION` unless preloaded. Preloading them would start background
workers or install hooks in every connection, even for users who never use
them. Cost: users who need one must rebuild the image or set
`POSTGRES_SHARED_PRELOAD_LIBRARIES`, and they are not in the image to preload.
Check: `tests/smoke.sh` creates every entry in `pg_available_extensions` and
fails on any error.

To add one anyway, add its attribute to `flake.nix` and its library to the
default preload list in `entrypoint.sh`.

## numpy is replaced by an empty path

PostGIS links GDAL, and nixpkgs' GDAL always builds Python bindings. Those
bindings keep numpy, BLAS, LAPACK, OpenBLAS and gfortran in the runtime
closure. `flake.nix` uses `replaceDependencies` to swap numpy for an empty
path with the same name. Rejected: overriding GDAL to build without Python,
which misses the binary cache, so GDAL and PostGIS compile on every CI run.
Also rejected: keeping numpy. Cost: GDAL's Python bindings in the image are
broken (nothing in PostgreSQL loads them), and the replacement relies on
nixpkgs keeping the numpy derivation name stable. If GDAL stops referencing
`python3Packages.numpy`, the replacement is a no-op and the size returns.
Check, on 2026-10-30 with nixpkgs 1c89083e: the image went from 964 MB to
714 MB, `nix path-info -r $(nix build .#postgres --print-out-paths)` lists
numpy only as the empty path, and with
`postgis.gdal_enabled_drivers = 'ENABLE_ALL'` `st_gdaldrivers()` returns 134
drivers.

## PL/JS instead of PL/v8

`pljs.nix` packages PL/JS 1.0.5, which embeds QuickJS. Rejected: plv8, which
nixpkgs removed because it depends on the insecure NodeJS 20 build. Cost: PL/JS
is a newer project and QuickJS is slower than V8, and it is not in the binary
cache, so CI compiles it. Check: the smoke test's
`pljs` line.

## Data directory and user

`PGDATA` defaults to `/var/lib/postgresql/18/data` and the server runs as
999:999, matching the official image's uid. The self-signed certificate lives
inside `PGDATA` so a single volume holds all state. Rejected: running as root
and dropping privileges in the entrypoint, which needs `gosu` and breaks
`runAsNonRoot` in Kubernetes. Cost: a volume created for another uid must be
chowned first. Check: `docker run --rm --entrypoint id ghcr.io/jbsiddall/postgres-sunday-roast:18`
prints `uid=999(postgres)`.

## s6 supervises the bundled services

Choice: after bootstrap, the entrypoint writes a service tree under
`/run/psr-services/services` and execs `s6-svscan` as PID 1. All processes run as
999:999 and inherit the container's stdout/stderr. `SIGTERM` stops the tree;
PostgreSQL's `down-signal` is `INT` for fast shutdown. PgBouncer receives `QUIT`
because its `TERM` waits for all clients, including idle admin connections.
A stop marker distinguishes
normal shutdown from PostgreSQL failure. Its finish script stops svscan, returns
125 to prevent restart, and passes a failure status to svscan's finish script.
Rejected: systemd, root at startup, and restarting PostgreSQL inside the
container. Cost: `/run/psr-services` must be writable (an `emptyDir` with a read
only root filesystem); a PostgreSQL exit requires a container restart. Check:
CI runs as uid 999, stops with a busy `pg_sleep(600)` client and requires exit 0
within Docker's default timeout, then kills PostgreSQL and requires a nonzero
container exit. Other services remain under s6's normal restart policy.

## PgBouncer over the trusted socket

Choice: PgBouncer listens on configurable port 6432 by default and maps all
database names to PostgreSQL on `/run/postgresql`. `auth_user=POSTGRES_USER`
and `auth_dbname=postgres` fetch login roles' hashes with an expiry-aware
`auth_query`. The auth user needs no `auth_file` entry because the socket is
trusted; SCRAM hashes come from the same server, and there is no forced backend
user. Client auth follows the host-auth variable, and TLS uses PostgreSQL's
certificate and key. The generated `/run/psr-services/pgbouncer.ini` is mode 0600
and contains no password. Transaction pooling with `max_prepared_statements=100`
supports protocol-level named statements. Rejected: maintaining a userlist,
forcing all connections through the pooler, pgcat (absent from nixpkgs), and
PgBouncer's unused systemd integration. Cost: session state requires session
pooling or direct connections; unusual admin role names containing whitespace
or commas cannot be represented in PgBouncer's user lists. The pooler assumes
trusted local auth. Check: smoke tests exercise TCP passwords, a newly created
role, TLS, wrong-password rejection and `show pools`. On the pinned nixpkgs,
removing systemd from PgBouncer's build inputs and appending `--without-systemd`
reduces its added closure from 88 MB to 2 MB; audit the final runtime closure
for systemd after building.

## HTTP services require explicit access configuration

Choice: PostgREST starts by default on port 3000 and connects directly over the
socket, with only URI, schema and port defaults. Its native connection retry
handles startup ordering. No anonymous role or JWT secret is supplied. pgweb
starts only with `PGWEB_ENABLED`, listens on port 8081 in sessions mode, and
reads optional basic-auth credentials from its environment. Rejected: automatic
anonymous API access, a default JWT secret, and preconnecting pgweb as the
superuser. Cost: PostgREST needs a restricted authenticator and explicit grants
before use; pgweb can reach any host the container can reach and must stay
private. PostgREST's binary output avoids the Haskell library closure. Check:
the smoke test requires an anonymous API refusal and, when enabled, a pgweb
HTTP response; CI also checks pgweb is off by default and both default services
can be disabled.

## No lazy service startup

Choice: enabled services start together under s6. Rejected: starting on first
connection, which needs a socket-owning proxy on every request or systemd
socket activation. The image cannot run systemd, and proxying adds a hop and
another process to supervise. Cost: idle services consume memory even when
unused; disable unwanted services with their environment switches. Check:
compare idle RSS on the built image before reconsidering a proxy.

<!-- idle RSS: filled in after the host run -->
