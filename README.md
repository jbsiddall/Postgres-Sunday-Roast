# Postgres Sunday Roast

PostgreSQL 18 with all the trimmings: one container image with 92 extensions
ready to `CREATE EXTENSION`. It includes vectors, geospatial, DuckDB analytics,
cron jobs, incremental views, queues, GraphQL, and Python and JavaScript
functions, with SSL on for new clusters.

It is built with [Nix](https://nixos.org) from a pinned nixpkgs, so every build
uses the same inputs. It runs as a non-root user and follows the official
`postgres` image's environment variables, so it is a drop-in replacement for
most setups.

```sh
docker run -d --name pg -p 5432:5432 -e POSTGRES_PASSWORD=change-me \
  -v pgdata:/var/lib/postgresql ghcr.io/jbsiddall/postgres-sunday-roast:18
```

```sh
psql "postgres://postgres:change-me@localhost:5432/postgres?sslmode=require" \
  -c 'create extension vector' -c "select '[1,2,3]'::vector <-> '[1,2,4]'"
```

## What's on the plate

| Area | Extensions |
| --- | --- |
| AI and vectors | `vector` (pgvector 0.8), `vectorscale` (DiskANN) |
| Analytics | `pg_duckdb` (DuckDB inside Postgres; query Parquet and CSV files) |
| Geospatial | `postgis` with raster, topology and tiger geocoder, `pgrouting`, `h3`, `h3_postgis` |
| Scheduling and views | `pg_cron`, `pg_ivm` (incrementally maintained materialised views) |
| Procedural languages | `plpython3u` (Python 3.14), `pljs` (JavaScript on QuickJS), `plpgsql_check` |
| Queues and APIs | `pgmq`, `pg_graphql`, `http` (HTTP requests from SQL), `pgjwt` |
| Search and similarity | `rum`, `pg_bigm`, `pg_similarity`, `pg_trgm`, `fuzzystrmatch`, `unaccent` |
| Graphs | `age` (Apache AGE, openCypher queries) |
| Data types | `pg_uuidv7`, `ip4r`, `semver`, `pg_rational`, `hll`, `roaringbitmap`, `citext`, `ltree`, `hstore`, `cube`, `seg`, `isn` |
| History and time | `temporal_tables`, `periods` (SQL:2011 system versioning) |
| Operations | `pg_partman`, `pg_repack`, `pg_hint_plan`, `hypopg`, `pg_background`, `pg_stat_statements`, `pgtap` |
| Security and privacy | `pgsodium` (libsodium), `anon` (masking and anonymisation), `pgcrypto`, `sslinfo` |
| Foreign data | `postgres_fdw`, `tds_fdw` (SQL Server and Sybase), `file_fdw`, `dblink`, `pg_csv` |

It also includes every extension that ships with PostgreSQL itself, plus three
modules that are loaded rather than created: `safeupdate` (blocks `UPDATE` and
`DELETE` without a `WHERE`), `wal2json` (logical decoding output) and
`auto_explain`. To see the full list with versions, run
`select name, default_version from pg_available_extensions order by 1`.

For clusters created by this image, `pg_stat_statements`, `pg_cron`, `pg_ivm`
and `pg_duckdb` are preloaded.
`pg_cron` lives in the `postgres` database, and its jobs run in background
workers, so they need no password.

```sql
-- in the postgres database
create extension pg_cron;
select cron.schedule_in_database('nightly-vacuum', '0 3 * * *', 'vacuum analyze', 'app');
```

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `POSTGRES_PASSWORD` | required on first start | Password of `POSTGRES_USER`. Optional for an existing cluster or with `POSTGRES_HOST_AUTH_METHOD=trust`. |
| `POSTGRES_USER` | `postgres` | Superuser created on first start. |
| `POSTGRES_DB` | `$POSTGRES_USER` | Database created on first start. |
| `POSTGRES_INITDB_ARGS` | none | Extra `initdb` flags, e.g. `--no-data-checksums` (18 enables checksums by default). |
| `POSTGRES_INITDB_WALDIR` | inside `PGDATA` | Put the write-ahead log in another directory, e.g. a faster volume. |
| `LANG` | `en_US.UTF-8` | Locale of a new cluster. `C.UTF-8` is the only other locale in the image. |
| `POSTGRES_HOST_AUTH_METHOD` | `scram-sha-256` | Authentication for TCP connections. `trust` needs no password from anyone who can reach the port, so use it only for throwaway local databases. |
| `PGDATA` | `/var/lib/postgresql/18/docker` | Data directory. Mount a volume at `/var/lib/postgresql`. |
| `POSTGRES_SSL_CERT_FILE`, `POSTGRES_SSL_KEY_FILE` | self-signed under `/run/psr-services` for new clusters | Use your own certificate, e.g. from a Kubernetes secret. |
| `POSTGRES_SSL_CN` | `postgres` | Common name of the generated certificate. |
| `POSTGRES_SHARED_PRELOAD_LIBRARIES` | `pg_stat_statements,pg_cron,pg_ivm,pg_duckdb` | Change what is preloaded. |
| `POSTGRES_CRON_DATABASE` | `postgres` | Database that holds `pg_cron`'s tables. |
| `PGBOUNCER_ENABLED` | `true` | Start the connection pooler. |
| `PGBOUNCER_PORT` | `6432` | Pooler's TCP port; configurable independently of PostgreSQL. |
| `PGBOUNCER_POOL_MODE` | `transaction` | Pool by `transaction`, `session` or `statement`. See Services. |
| `PGBOUNCER_DEFAULT_POOL_SIZE` | `20` | Maximum server connections per database/user pair. |
| `PGBOUNCER_MAX_CLIENT_CONN` | `100` | Maximum pooler client connections. |
| `POSTGREST_ENABLED` | `true` | Start the HTTP database API. |
| `PGRST_SERVER_PORT` | `3000` | PostgREST's HTTP port. |
| `PGRST_DB_URI` | socket, `$POSTGRES_USER`, `$POSTGRES_DB` | PostgREST's libpq connection string. Use a restricted authenticator before enabling requests. |
| `PGRST_DB_SCHEMAS` | `public` | Schemas exposed by PostgREST. |
| `PGRST_DB_ANON_ROLE` | unset | Role for anonymous requests; none are accepted by default. |
| `PGRST_JWT_SECRET` | `$POSTGRES_PASSWORD` if at least 32 bytes | JWT verification secret or JWK/JWKS. Explicit values win; a short or missing password leaves JWT auth off. |
| `PGRST_JWT_SECRET_FILE` | unset | Entrypoint helper: read the JWT secret from this file instead; prevents the password fallback. |
| `PGRST_JWT_SECRET_IS_BASE64` | `false` | Decode the JWT secret as base64 before use. |
| `PGRST_JWT_AUD` | unset | Expected JWT `aud` claim. |
| `PGRST_JWT_ROLE_CLAIM_KEY` | `.role` | Path to the JWT claim containing the database role. |
| `PGRST_DB_PRE_REQUEST` | unset | Schema-qualified function called before each API request. |
| `PGWEB_ENABLED` | `false` | Start the web SQL client. |
| `PGWEB_PORT` | `8081` | pgweb's HTTP port, bound to `0.0.0.0`. |
| `PGWEB_AUTH_USER` | `$POSTGRES_USER` | HTTP basic-auth user when pgweb is enabled; explicit values win. |
| `PGWEB_AUTH_PASS` | `$POSTGRES_PASSWORD` | Required HTTP basic-auth password when enabled, read from the environment, never process arguments; explicit values win. |
| `PGWEB_AUTH_PASS_FILE` | unset | Read the basic-auth password from this file instead. |

`POSTGRES_PASSWORD`, `POSTGRES_USER`, `POSTGRES_DB` and `POSTGRES_INITDB_ARGS`
as well as `PGRST_JWT_SECRET` and `PGWEB_AUTH_PASS` can instead be read from a
file, such as a Docker or Kubernetes secret, by setting `POSTGRES_PASSWORD_FILE`
and so on. Setting both forms is an error.

Service switches accept `1`/`true`/`yes`/`on` and `0`/`false`/`no`/`off`
(case insensitive); an empty value disables the service. Other values are errors.

Settings: any arguments after the image name go to `postgres` and override the
defaults, both during init scripts and afterwards. A leading `postgres` is
optional, so Compose files written for the official image keep working:

```sh
docker run ... ghcr.io/jbsiddall/postgres-sunday-roast:18 -c shared_buffers=1GB -c duckdb.max_memory=2GB
```

Any other command, such as `psql`, `pg_dump` or `bash`, runs instead of the
server.

Init scripts: on first start, `*.sql`, `*.sql.gz` and `*.sh` files in
`/docker-entrypoint-initdb.d` run once, in name order, against
`POSTGRES_DB`. An executable `*.sh` file is run; any other is sourced, with
`"${psql[@]}"` set to a `psql` command for `POSTGRES_DB`. Both see
`POSTGRES_USER` and `POSTGRES_DB`, and `PGHOST`, `PGUSER` and `PGDATABASE`, so
a plain `psql` works too. During that step the server only listens on its Unix
socket, so clients cannot connect to a half-built database.

Stopping: the image's stop signal is `SIGTERM`. s6 stops all services and sends
PostgreSQL `SIGINT` for a fast shutdown, disconnecting busy clients cleanly.
If PostgreSQL exits unexpectedly, the container exits too; s6 restarts the
other services if they fail. Service output goes to the container log.

Authentication on new clusters: local socket connections are trusted, and every TCP connection
must use a password (SCRAM-SHA-256, unless `POSTGRES_HOST_AUTH_METHOD` says
otherwise). New clusters have SSL on; to force it for TCP,
change `host` to `hostssl` in `pg_hba.conf`.

User: the server runs as uid and gid 999. Follow the
[volume preparation procedure](#kubernetes) before attaching a volume.

## Services

| Service | Container port | Default |
| --- | --- | --- |
| PostgreSQL | `5432` | On |
| PgBouncer | `6432` (`PGBOUNCER_PORT`) | On |
| PostgREST | `3000` (`PGRST_SERVER_PORT`) | On, anonymous requests refused |
| pgweb | `8081` (`PGWEB_PORT`) | Off |

Publish only the ports you need with `-p`. For example, add `-p 6432:6432`
and connect with the same database credentials through the pooler:

```sh
# Direct connection
psql 'postgres://postgres:change-me@localhost:5432/postgres?sslmode=require'
# Pooled connection
psql 'postgres://postgres:change-me@localhost:6432/postgres?sslmode=require'
psql 'postgres://postgres:change-me@localhost:6432/pgbouncer?sslmode=require' -c 'show pools'
```

PgBouncer maps any database name to the same database over `/run/postgresql`.
It looks up login roles and password hashes in PostgreSQL, including password
expiry, with no userlist to maintain. Its client authentication follows
`POSTGRES_HOST_AUTH_METHOD` (`scram-sha-256`, `md5` or `trust`), and it accepts
TLS and plain TCP with the same certificate as PostgreSQL. Keep local socket
authentication trusted for these services. PgBouncer's admin and stats user is
`POSTGRES_USER`; names with whitespace or commas require disabling PgBouncer
because its user lists cannot represent them. Other host authentication methods
also require `PGBOUNCER_ENABLED=false`. On an existing volume, keep the host
authentication variable consistent with `pg_hba.conf`.

Transaction pooling supports drivers' protocol-level named prepared statements
(`max_prepared_statements=100`), but session `SET`, session advisory locks,
`LISTEN` and SQL `PREPARE`/`EXECUTE` cannot be relied on across transactions.
Use `PGBOUNCER_POOL_MODE=session` or connect directly for session state. The
pool size is per database/user pair, so many pairs can exhaust PostgreSQL's
connection limit.

PostgREST receives all user-supplied `PGRST_*` variables unchanged, alongside
the defaults above, and retries database connections while PostgreSQL starts.
These are the same variables as the official `postgrest/postgrest` image; see
the [v14 configuration reference](https://docs.postgrest.org/en/v14/references/configuration.html)
and [official Docker instructions](https://docs.postgrest.org/en/v14/explanations/install.html#docker).
`PGRST_JWT_SECRET_FILE` is an entrypoint helper; the native file syntax is
`PGRST_JWT_SECRET=@/path/to/secret`. Other native settings, including
`PGRST_APP_SETTINGS_*`, also pass through.

`PGRST_DB_ANON_ROLE` is optional and unset by default, so anonymous requests
are refused. If both `PGRST_JWT_SECRET` and `PGRST_JWT_SECRET_FILE` are unset,
the JWT secret defaults to `POSTGRES_PASSWORD` after `_FILE` expansion. A
missing password leaves JWT unset. A password shorter than 32 bytes leaves
JWT unset and prints a warning; the container still starts. PostgREST v14
rejects an explicitly configured short secret at startup, before serving
requests. The docs call this 32 characters; the implementation checks UTF-8
bytes. Native secret formats and `PGRST_JWT_SECRET_IS_BASE64` still apply.

To sign a token with the default secret, use HS256 with `POSTGRES_PASSWORD`
as the signing key, a `role` claim naming the database role and a short-lived
`exp` claim. For the default user, a payload such as
`{"role":"postgres","exp":<Unix expiry time>}` gets superuser access over
HTTP with the default `PGRST_DB_URI`. Send the token as
`Authorization: Bearer <token>`. Signing requires the superuser password, so
this adds no privilege beyond that credential, but the token issuer now holds
the superuser password. Production should set a separate `PGRST_JWT_SECRET`
and use a restricted authenticator. The smoke test includes an OpenSSL HS256
signing example.

Create a restricted login role and grant it only the API roles it should
assume. For example, run this in the application database (or put it in an
init script):

```sql
create role authenticator login noinherit;
create role api_anon nologin;
grant api_anon to authenticator;
grant usage on schema public to api_anon;
-- Grant SELECT on specific tables or views that may be public:
-- grant select on public.items to api_anon;
```

Then recreate the container with these environment variables:

```sh
PGRST_DB_URI='host=/run/postgresql port=5432 user=authenticator dbname=app'
PGRST_DB_ANON_ROLE=api_anon
PGRST_JWT_SECRET_FILE=/run/secrets/postgrest-jwt
```

The secret file must hold a random secret of at least 32 characters (or a
JWK/JWKS). Grant additional API roles to `authenticator` as needed. Leaving
`PGRST_DB_URI` as the default superuser means any valid JWT can switch to any
role, including superusers. Use the restricted URI with a separate JWT secret
and explicit grants. See the [PostgREST role model](https://docs.postgrest.org/en/v14/references/auth.html).

Enable pgweb with `PGWEB_ENABLED=1` and publish port 8081. It starts in sessions
mode with no preconfigured database; enter a database URL in the browser.
HTTP basic auth is always enabled: the login defaults to `POSTGRES_USER`
(`postgres`) and `POSTGRES_PASSWORD` after `_FILE` expansion. Explicit
`PGWEB_AUTH_USER` and `PGWEB_AUTH_PASS` (or `PGWEB_AUTH_PASS_FILE`) override
the defaults. If no password resolves, startup fails with an error asking for
`PGWEB_AUTH_PASS` or `POSTGRES_PASSWORD`, even on an existing database or with
trust authentication. The default web login equals the database superuser
login; set separate web credentials when that is unsuitable. pgweb 0.17.0
supports `--auth-user` / `--auth-pass`; this image uses its native
`PGWEB_AUTH_USER` / `PGWEB_AUTH_PASS` environment variables to keep the password
out of process arguments. Use a TLS reverse proxy for remote access. pgweb can
connect to any host the container can reach, including databases on trusted
local sockets. Do not expose it publicly.

Enabled services start together under `s6-svscan` as PID 1, with no root,
capabilities or systemd. Services do not start lazily on the first connection;
the tradeoff is recorded in [IMPLEMENTATION_DECISIONS.md](IMPLEMENTATION_DECISIONS.md).

Service environments contain only their own settings: PostgREST gets `PGRST_*`,
pgweb gets its basic-auth credentials, and PgBouncer reads its password-free
configuration. PostgreSQL, PostgREST and pgweb also get the other `PG*`
variables, which are libpq and server inputs such as `PGSERVICEFILE`,
`PGPASSFILE` and `PGSSLROOTCERT`. s6 inherits none of these
credentials. This reduces accidental disclosure in process diagnostics; all
services still run as the same uid and share trusted local database access.

For a read-only Docker root filesystem, keep data on a volume and mount:

```sh
docker run -d --name pg --read-only \
  --tmpfs /run/postgresql:mode=1777 \
  --tmpfs /run/psr-services:exec,mode=1777 --tmpfs /tmp \
  -e POSTGRES_PASSWORD=change-me -v pgdata:/var/lib/postgresql \
  ghcr.io/jbsiddall/postgres-sunday-roast:18
```

`/run/psr-services` must permit execution because s6 executes generated run
and shutdown scripts there. Docker tmpfs mounts need the explicit `exec` flag.

### Docker Compose

```yaml
services:
  db:
    image: ghcr.io/jbsiddall/postgres-sunday-roast:18
    environment:
      POSTGRES_PASSWORD: change-me
      POSTGRES_DB: app
    ports: ["5432:5432"]
    volumes:
      - pgdata:/var/lib/postgresql
      - ./initdb:/docker-entrypoint-initdb.d:ro
volumes:
  pgdata:
```

### Kubernetes

For new and imported clusters, set `securityContext.runAsUser` and
`runAsGroup` to 999, with `runAsNonRoot: true`, and mount the data volume at
`/var/lib/postgresql`. A PVC does not inherit the image directory's ownership;
the entrypoint never changes ownership. Prepare the volume once:

1. With PostgreSQL stopped, mount the data PVC read-write at
   `/var/lib/postgresql` in a one-off maintenance pod. Run its utility container
   as UID/GID 0 (`runAsUser: 0`, `runAsGroup: 0`, `runAsNonRoot: false`),
   without pod-wide `fsGroup`.
2. For an **empty volume only**, change just the mount root:

   ```sh
   chown 999:999 /var/lib/postgresql
   chmod u+rwx /var/lib/postgresql
   ```

   The database process creates its own restricted PGDATA beneath it. For an
   imported official cluster already owned by 999:999, keep its ownership and
   file modes; do not recursively chown it. For a different database UID, use a
   maintenance container with GNU `find`, `stat` and `chown`. Read it with
   `old_uid="$(stat -c %u /var/lib/postgresql/18/docker)"`, confirm it is the
   expected nonzero database UID, then remap only that owner's files:

   ```sh
   find /var/lib/postgresql/18/docker -xdev -uid "$old_uid" -exec chown -h 999:999 '{}' +
   ```

   Ensure 999 can traverse `/var/lib/postgresql` and its `18` directory. Prepare
   separately mounted WAL and tablespaces at their own mount paths. Preserve
   root-owned TLS keys as root:999 with mode 0640; database-owned keys must stay
   0600. Do not use recursive chmod or change root-owned 0640 keys to database
   ownership without also restricting them to 0600.
3. Remove the maintenance pod before starting PostgreSQL as 999:999. If policy
   or the storage backend disallows these ownership changes, have the storage
   administrator perform the same preparation before attaching the PVC.

Do not set pod-wide `fsGroup`. Kubelet's recursive permission pass changes file
modes inside supported volumes: a database-owned TLS key at 0600 becomes 0660,
which [PostgreSQL 18 rejects](https://www.postgresql.org/docs/18/ssl-tcp.html).
SSL keys on data volumes changed by `fsGroup` are unsupported. Before reusing
such a volume, remove `fsGroup` and restore affected key permissions separately
while the database is stopped. The entrypoint leaves every file inside PGDATA
alone, including keys. Its generated keys live outside PGDATA under
`/run/psr-services/tls.*`, with mode 0600; supplied keys stay at their configured
paths and retain their modes.

On every start, the entrypoint resets an existing PGDATA owned by the current
user to mode 0700, matching the official image. This repairs the directory
itself if a previous mount used `fsGroup` and also resets 0750 clusters created
with `initdb --allow-group-access`. It does not repair file modes inside it.
See the [kubelet v1.35.0 permission masks](https://raw.githubusercontent.com/kubernetes/kubernetes/v1.35.0/pkg/volume/volume_linux.go).

With `readOnlyRootFilesystem: true`, also mount writable default
`emptyDir: {}` volumes at `/run/postgresql`, `/run/psr-services` (s6 state,
generated configuration and TLS keys) and `/tmp`. Kubelet v1.35.0
[creates these directory-backed mounts with mode 0777](https://raw.githubusercontent.com/kubernetes/kubernetes/v1.35.0/pkg/volume/emptydir/empty_dir.go),
so 999:999 can write without `fsGroup`. They permit execution by default; no
Docker-style `exec` option is needed. A cluster policy or mount override must
not make `/run/psr-services` `noexec`.

For the remaining import checks, follow
[Switching from the official image](#switching-from-the-official-image).

For a supplied TLS pair, set `POSTGRES_SSL_CERT_FILE` and
`POSTGRES_SSL_KEY_FILE` to the mounted paths. Prepare the key as owned by 999
with mode 0600, or by root with mode 0640 and group 999, and ensure 999:999 can
traverse its parent directories and read the certificate. A Kubernetes TLS
Secret's `defaultMode` alone does not give its root-owned key group 999 without
`fsGroup`. Merge this fragment into your database pod, keeping its prepared data
volume, runtime mounts and password/service environment:

```yaml
spec:
  securityContext:
    runAsUser: 999
    runAsGroup: 999
    runAsNonRoot: true
  initContainers:
    - name: prepare-tls
      image: ghcr.io/jbsiddall/postgres-sunday-roast:18
      securityContext:
        runAsUser: 0
        runAsGroup: 0
        runAsNonRoot: false
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
          add: [CHOWN]
      command: [/bin/bash, -euc]
      args:
        - |
          umask 077
          mkdir -p /tls-ready/pair
          cp /tls-source/tls.crt /tls-ready/pair/server.crt
          cp /tls-source/tls.key /tls-ready/pair/server.key
          chmod 0700 /tls-ready/pair
          chmod 0600 /tls-ready/pair/server.crt /tls-ready/pair/server.key
          chown 999:999 /tls-ready/pair/server.crt /tls-ready/pair/server.key
          chown 999:999 /tls-ready/pair
      volumeMounts:
        - { name: tls-source, mountPath: /tls-source, readOnly: true }
        - { name: tls-ready, mountPath: /tls-ready }
  containers:
    - name: postgres
      image: ghcr.io/jbsiddall/postgres-sunday-roast:18
      env:
        - { name: POSTGRES_SSL_CERT_FILE, value: /etc/postgres-tls/pair/server.crt }
        - { name: POSTGRES_SSL_KEY_FILE, value: /etc/postgres-tls/pair/server.key }
      volumeMounts:
        - { name: tls-ready, mountPath: /etc/postgres-tls, readOnly: true }
  volumes:
    - name: tls-source
      secret:
        secretName: postgres-tls
        defaultMode: 0400
    - name: tls-ready
      emptyDir: {}
```

UID 0 can read the root-owned 0400 Secret as its owner and write into the
default 0777 `emptyDir` described above; only the ownership transfer needs
`CHOWN`. The copy ends as 999:999 with a 0600 key in a 0700 directory. After
updating the Secret, recreate the pod to rerun the init container for rotation.
If policy disallows a root init container, use an administrator-prepared mount
with the same final access. Do not broaden the key's permissions.

Pin both image references by digest
(`ghcr.io/jbsiddall/postgres-sunday-roast@sha256:...`); each CI run prints the
digest in its summary.

## Tags

| Tag | Meaning |
| --- | --- |
| `18` and `latest` | Latest build of PostgreSQL 18. |
| `18.6` | Latest build of that minor version. |
| `18.6-<commit>` | One exact build. It never moves. |

Images are built for `linux/amd64`.

## Size

The image is 727 MB uncompressed, which is 244 MB to download. The official
`postgres:18` image is 464 MB and includes none of these extensions or
services.

Nix copies only runtime files into the image, so compilers and build
dependencies never end up in it. PgBouncer is built without systemd and
PostgREST uses its binary output to keep the runtime closure small. The biggest
parts are Python (for PL/Python), DuckDB, GDAL and PROJ (for PostGIS) and ICU.

## Switching from the official image

Mount an official PostgreSQL 18 volume at `/var/lib/postgresql` without a
`PGDATA` override. Both images use `/var/lib/postgresql/18/docker` and the
Debian official image's `postgres` user is 999:999. Verified on 2026-10-31
against [Dockerfile commit e00e1bd](https://github.com/docker-library/postgres/blob/e00e1bd34ec5c8a8e7ad89b273b3d42efaf6d5bc/18/trixie/Dockerfile).
This does not cover Alpine images, another architecture or another major version.

1. Back up first and test restoring the backup. Record the old image digest,
   PostgreSQL version, `SHOW data_checksums`, database locales and installed
   extensions (`SELECT extname, extversion FROM pg_extension` in each database).
   Stop application traffic, then stop the old container cleanly. Keep a stopped
   copy or snapshot of the volume; never run both servers against it. Dump and
   restore into a new volume remains an alternative that rebuilds indexes.
2. Check the stopped cluster with `pg_controldata -D /var/lib/postgresql/18/docker`
   using a one-off container and the same volume. Keep PostgreSQL major version
   18 and architecture unchanged. Preserve mounts for external WAL, tablespaces,
   certificates and included configuration, at their original paths. Confirm
   the target has the locales and extension libraries the cluster uses; this
   image contains only `en_US.UTF-8` and `C.UTF-8` glibc locales.
3. Mount the same volume and run as 999:999. For Kubernetes, use this pod
   security context (the volume must already belong to 999:999):

   ```yaml
   securityContext:
     runAsUser: 999
     runAsGroup: 999
     runAsNonRoot: true
   ```

   Follow the imported-cluster branch of the
   [volume preparation procedure](#kubernetes); do not set `fsGroup`. The
   entrypoint resets only the PGDATA directory to 0700 when owned by the
   current user, including a directory previously broadened to
   2770. The
   [official entrypoint at e00e1bd](https://github.com/docker-library/postgres/blob/e00e1bd34ec5c8a8e7ad89b273b3d42efaf6d5bc/18/trixie/docker-entrypoint.sh#L39-L41)
   does the same, including resetting mode 0750 to 0700. Group access through
   PGDATA is therefore removed; its contents are left alone. This entrypoint
   never chowns an existing cluster or repairs TLS key modes.
   With a read-only root filesystem, use the three writable default `emptyDir`
   mounts described above and keep `/run/psr-services` executable.
   For example, with Docker:

   ```sh
   docker run -d --name pg --user 999:999 \
     -e PGBOUNCER_ENABLED=false -e POSTGREST_ENABLED=false \
     -v pgdata:/var/lib/postgresql ghcr.io/jbsiddall/postgres-sunday-roast:18
   ```

4. Before reopening traffic, inspect logs and connect to every application
   database. Confirm your rows, checksums, authentication, SSL, extensions and
   settings. The entrypoint skips initdb and init scripts, leaves `pg_hba.conf`,
   configuration and certificates alone, and preserves existing server settings.
   It supplies `unix_socket_directories=/run/postgresql` for bundled services;
   command arguments still win. It does not replace an imported preload list,
   worker limits, listen addresses or SSL policy. Explicit SSL/preload/cron
   environment variables still override their settings. Enable bundled services
   only after checking their trusted-socket and role requirements above.
   Set `POSTGRES_USER` and `POSTGRES_DB` to existing roles and databases;
   setting `POSTGRES_PASSWORD` does not reset an existing role's password.
   PgBouncer generates its own runtime certificate when PostgreSQL has SSL off.
5. Resolve collation changes before serving queries. The pinned official
   `postgres:18` (18.6, trixie) contains Debian glibc 2.41
   (`libc6 2.41-12+deb13u4`); this flake's nixpkgs pin contains glibc 2.44.
   Sources: [Debian libc6](https://packages.debian.org/trixie/libc6),
   [pinned Nix definition](https://github.com/NixOS/nixpkgs/blob/1c89083e451e891152365b799595cf7790a43325/pkgs/development/libraries/glibc/common.nix).
   Check your actual old digest; older Debian tags can differ. A "collation
   version mismatch" warning means the recorded version differs from the
   current provider. It does not block startup or rebuild anything. B-tree
   indexes on `text`/`varchar` (including primary keys), expression indexes
   and other objects that depend on changed libc or ICU collations can retain
   an obsolete order. Index scans may return wrong results without an error;
   an absence of warnings does not prove the sort rules are unchanged.
   [Binary `C`/`POSIX` collations](https://www.postgresql.org/docs/18/collation.html)
   do not use language-specific sort rules.
   See [PostgreSQL's collation guidance](https://www.postgresql.org/docs/18/sql-altercollation.html).

   Connect as a superuser to each affected database, including `postgres`
   and any template database with affected objects. Rebuild affected indexes
   first; rebuilding all user indexes in the database is a conservative option:

   ```sql
   -- Connected to app, with application traffic stopped.
   REINDEX DATABASE app;
   ALTER DATABASE app REFRESH COLLATION VERSION;
   ```

   `REINDEX DATABASE` runs outside a transaction. Resolve any duplicate-key
   errors and rebuild other collation-dependent objects before refreshing.
   It excludes system catalogs; use `REINDEX SYSTEM app` if their indexes
   are affected too. See [REINDEX](https://www.postgresql.org/docs/18/sql-reindex.html).
   For explicitly named collations, also rebuild their dependent objects and
   then run `ALTER COLLATION schema.collation_name REFRESH VERSION` in that
   database. List mismatches with:

   ```sql
   SELECT datname, datcollversion, pg_database_collation_actual_version(oid)
   FROM pg_database
   WHERE datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid);

   SELECT oid::regcollation, collversion, pg_collation_actual_version(oid)
   FROM pg_collation
   WHERE collversion IS DISTINCT FROM pg_collation_actual_version(oid);
   ```

   Refreshing version metadata alone only silences the warning. It does not
   repair indexes. See [ALTER DATABASE](https://www.postgresql.org/docs/18/sql-alterdatabase.html).
6. Compare extensions in every database with `pg_available_extension_versions`.
   A missing `shared_preload_libraries` entry prevents startup; other missing
   libraries can fail when a function is first used. Restore compatible
   libraries or rebuild the image. Where supported by the extension's upgrade
   path, run `ALTER EXTENSION extension_name UPDATE` (or `UPDATE TO 'version'`)
   in each database, then test its functions. Changing images does not update
   extension SQL objects automatically. Do not assume an older bundled version
   can read a newer extension's data. See [ALTER EXTENSION](https://www.postgresql.org/docs/18/sql-alterextension.html)
   and [shared library preloading](https://www.postgresql.org/docs/18/runtime-config-client.html#RUNTIME-CONFIG-CLIENT-PRELOAD).

### Binary compatibility and checksums

PostgreSQL checks `PG_VERSION` and `pg_control` at startup. A different major
version, control/catalog format, data or WAL block size, alignment, floating-point
format, or float8/int8 pass-by-value ABI fails loudly. PostgreSQL 18 always uses
integer timestamps; the old integer-versus-float timestamp build option is not
an 18 setting. A valid WAL segment size is read from the cluster (powers of two
from 1 MB to 1 GB); it need not equal initdb's default of 16 MB. Invalid sizes
fail at startup. These checks do not detect collation ordering problems.
Sources: [18.6 control checks](https://github.com/postgres/postgres/blob/REL_18_6/src/backend/access/transam/xlog.c),
[major-version check](https://github.com/postgres/postgres/blob/REL_18_6/src/backend/utils/init/miscinit.c),
[control fields](https://github.com/postgres/postgres/blob/REL_18_6/src/include/catalog/pg_control.h),
[timestamp types](https://github.com/postgres/postgres/blob/REL_18_6/src/include/datatype/timestamp.h).

PostgreSQL 18 initdb enables data checksums by default. The official entrypoint
passes the username and password file, optional `--waldir`, and user-supplied
`POSTGRES_INITDB_ARGS`; it does not disable checksums by default. Reusing a
cluster preserves its checksum setting, including an explicit
`--no-data-checksums`. Check `SHOW data_checksums` after startup; optionally
run `pg_checksums --check` on a cleanly stopped checksummed cluster.
Sources: [initdb](https://www.postgresql.org/docs/18/app-initdb.html),
[official entrypoint at e00e1bd](https://github.com/docker-library/postgres/blob/e00e1bd34ec5c8a8e7ad89b273b3d42efaf6d5bc/docker-entrypoint.sh),
[pg_checksums](https://www.postgresql.org/docs/18/app-pgchecksums.html),
[pg_controldata](https://www.postgresql.org/docs/18/app-pgcontroldata.html).

### Existing PSR volumes

Earlier builds used `/var/lib/postgresql/18/data`. Keep that volume and set
`PGDATA=/var/lib/postgresql/18/data`. If the new default has no cluster and
that old path has `PG_VERSION`, startup refuses to initialise a new database
and prints this override. No migration, move, deletion or symlink is performed.

Clusters created by this build have a `.psr-managed` marker so the image's
SSL, preload and worker defaults also apply on restart. Imported clusters,
including older PSR clusters without the marker, keep their stored settings.
For older PSR clusters that relied on command-line defaults, explicitly set
`POSTGRES_SHARED_PRELOAD_LIBRARIES`, SSL certificate/key variables and other
needed server arguments when recreating the container. Generated certificates
now live in unique directories under `/run/psr-services`; they are regenerated
on restart. Mount your own pair for stable certificate identity.

## Build it yourself

You need Nix with flakes enabled, on x86_64 Linux.

```sh
nix build .#default            # result is a docker-archive tarball
docker load < result
nix build .#postgres           # just PostgreSQL and its extensions, no image
```

To add an extension, find its attribute name under `postgresql18Packages` on
[search.nixos.org](https://search.nixos.org/packages?query=postgresql18Packages),
add it to the list in `flake.nix`, then run the smoke test against a container:

```sh
docker run -d --name smoke -e POSTGRES_PASSWORD=smoke-only-at-least-32-characters \
  -e POSTGRES_DB=app -e PGWEB_ENABLED=1 \
  -v "$PWD/tests/initdb:/docker-entrypoint-initdb.d:ro" postgres-sunday-roast:18.6
tests/smoke.sh smoke docker
```

The smoke test checks SSL, PgBouncer authentication and TLS, PostgREST's refusal
of anonymous requests, a JWT signed with the default password (when OpenSSL is
available), service secret isolation, pgweb basic auth when enabled, the
preloaded libraries, init scripts and `pg_cron`, then creates every available
extension. CI also checks service
switches and shutdown, runs on every pull request and pushes the image to GHCR
from `main`.

The volume reuse test creates a disposable volume using a digest-pinned
`postgres:18`, stops it cleanly, and checks its rows, cluster identity,
checksums and configuration in this image without a `PGDATA` override.
It prints `collation-version-warning: yes` or `no` without failing on the
warning, and removes the containers and volume even on failure:

```sh
tests/official-volume.sh postgres-sunday-roast:18.6 podman
# Or: tests/official-volume.sh postgres-sunday-roast:18.6 docker
```

## Not included

- Extensions that only work when preloaded into every connection: `pg_net`,
  `pg_squeeze`, `pg_textsearch`, `pgaudit` and `timescaledb`. Each adds a
  background process or hooks that every user pays for. Build your own image
  if you need them; [IMPLEMENTATION_DECISIONS.md](IMPLEMENTATION_DECISIONS.md)
  says how.
- `plv8`: nixpkgs removed it because it needs an insecure NodeJS 20 build.
  `pljs` runs JavaScript instead.
- Extensions that nixpkgs does not package, for example `orafce`,
  `pg_stat_monitor`, `pglogical`, `pg_jsonschema` and `wrappers`.

## License

The build files are Apache-2.0 licensed. PostgreSQL and each extension keep
their own licences.
