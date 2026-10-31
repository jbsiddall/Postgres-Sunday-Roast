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
container. Also rejected: immutable launcher wrappers to interpret scripts on
a noexec runtime mount; s6 executes run, finish and signal scripts directly,
so wrappers would add indirection for each hook. Cost: `/run/psr-services` must
be writable and executable (`--tmpfs /run/psr-services:exec,mode=1777` in Docker,
or a Kubernetes `emptyDir` with a read-only root filesystem); a PostgreSQL exit
requires a container restart. Check: CI starts services on a read-only root
with the explicit exec tmpfs flag.
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

## PostgREST defaults JWT authentication to the database password

Choice: PostgREST starts by default on port 3000 and connects directly over the
socket. Its native connection retry handles startup ordering. Per the user
request on 2026-10-31, when both JWT secret inputs are unset, use the expanded
`POSTGRES_PASSWORD` if it has at least 32 bytes. Otherwise leave JWT unset,
warning for short passwords without stopping the container. Preserve all
explicit `PGRST_*` inputs and leave the anonymous role unset. Rejected: always
requiring a separate JWT secret and automatic anonymous API access. Cost: with
the default superuser URI, the token issuer holds the superuser password and
can issue superuser tokens; short passwords disable JWT. Production needs a
separate signing secret, a restricted authenticator and explicit grants.
PostgREST's binary output avoids the Haskell library closure. Check:
`tests/smoke.sh` requires anonymous refusal and accepts an HS256 token signed
with `POSTGRES_PASSWORD`; CI starts a short-password container and requires
the warning. PostgREST v14's `Config.parseSecret` checks at least 32 bytes
during startup, so setting a short secret would prevent it from starting.

## pgweb always requires basic auth

Choice: pgweb starts only with `PGWEB_ENABLED`, listens on port 8081 in sessions
mode, and reads basic-auth credentials from its environment. Per the user
request on 2026-10-31, default the login to `POSTGRES_USER` and the expanded
`POSTGRES_PASSWORD`; explicit `PGWEB_AUTH_USER` and `PGWEB_AUTH_PASS` or its
file form win. Fail container startup when enabled without a resolved password.
Rejected: optional basic auth, unauthenticated startup when the database uses
trust or has an existing data directory, and preconnecting pgweb as superuser.
Cost: the default web login equals the database superuser login; pgweb can
reach any host the container can reach and must stay private. Check:
`tests/smoke.sh` requires HTTP 401 without credentials and HTTP 200 with the
default database credentials; CI requires a clear failure with no password.
The pinned pgweb 0.17.0 options support both auth flags and the prefixed envs.

## Service credentials stay with their consumer

Choice: save each enabled service's environment in a mode-0600 shell file,
load it in that service's run script, and clear the service variables before
execing s6. PostgREST gets all `PGRST_*` and pgweb its basic-auth pair.
PostgreSQL, PostgREST and pgweb also get every other `PG*` variable, because
those are libpq and server inputs (`PGSERVICEFILE`, `PGPASSFILE`, TLS paths).
PgBouncer needs no environment with socket auth. Variables are listed with
`${!PG@}`, not `compgen`: the image runs the entrypoint with a bash built
without `compgen`, and there it fails silently. Disabled services get no environment file.
Rejected: inheriting all expanded secrets in every process and putting secrets
in argv. Cost: credential files remain in the writable runtime directory for
service restarts; a shared uid and trusted socket are not a security boundary.
Check: `tests/entrypoint.sh`, run with the image's bash, covers routing of
libpq inputs and secrets; the smoke test reads actual `/proc/<pid>/environ`
values, requiring no
PostgREST JWT secret in PgBouncer, pgweb, PostgreSQL or s6 and no database
bootstrap password in any service environment.

## No lazy service startup

Choice: enabled services start together under s6. Rejected: starting on first
connection, which needs a socket-owning proxy on every request or systemd
socket activation. The image cannot run systemd, and proxying adds a hop and
another process to supervise. Cost: idle services consume memory even when
unused; disable unwanted services with their environment switches. Check:
compare idle RSS on the built image before reconsidering a proxy. On
2026-10-31, an idle default container (18.6, nixpkgs 1c89083e, podman) showed
PostgREST at 20 MB RSS and PgBouncer at 18 MB, both including shared libraries,
against 52 MB for the postmaster alone. Read it with
`grep VmRSS /proc/<pid>/status` inside the container.
