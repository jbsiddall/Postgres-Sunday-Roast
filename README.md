# Postgres Sunday Roast

PostgreSQL 18 with all the trimmings: one container image with 92 extensions
ready to `CREATE EXTENSION`. It includes vectors, geospatial, DuckDB analytics,
cron jobs, incremental views, queues, GraphQL, and Python and JavaScript
functions, with SSL on from the first start.

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

`pg_stat_statements`, `pg_cron`, `pg_ivm` and `pg_duckdb` are preloaded.
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
| `POSTGRES_INITDB_ARGS` | none | Extra `initdb` flags, e.g. `--data-checksums`. |
| `POSTGRES_INITDB_WALDIR` | inside `PGDATA` | Put the write-ahead log in another directory, e.g. a faster volume. |
| `LANG` | `en_US.UTF-8` | Locale of a new cluster. `C.UTF-8` is the only other locale in the image. |
| `POSTGRES_HOST_AUTH_METHOD` | `scram-sha-256` | Authentication for TCP connections. `trust` needs no password from anyone who can reach the port, so use it only for throwaway local databases. |
| `PGDATA` | `/var/lib/postgresql/18/data` | Data directory. Mount a volume at `/var/lib/postgresql`. |
| `POSTGRES_SSL_CERT_FILE`, `POSTGRES_SSL_KEY_FILE` | self-signed in `$PGDATA` | Use your own certificate, e.g. from a Kubernetes secret. |
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

Authentication: local socket connections are trusted, and every TCP connection
must use a password (SCRAM-SHA-256, unless `POSTGRES_HOST_AUTH_METHOD` says
otherwise). SSL is always on; to force it for TCP,
change `host` to `hostssl` in `pg_hba.conf`.

User: the server runs as uid and gid 999. If a volume was created for a
different uid, `chown -R 999:999` it first.

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

Set `securityContext.runAsUser`, `runAsGroup` and `fsGroup` to 999 and mount
the volume at `/var/lib/postgresql`. `runAsNonRoot: true` is supported. With
`readOnlyRootFilesystem: true`, also mount writable `emptyDir` volumes at
`/run/postgresql`, `/run/psr-services` (s6 state and generated configuration)
and `/tmp`, owned by uid 999 or writable through `fsGroup: 999`.
Kubernetes `emptyDir` volumes permit execution by default; no Docker-style
`exec` option is needed. A cluster policy or mount override must not make
`/run/psr-services` `noexec`.

PostgreSQL refuses a private key that others can read. To use a certificate
from a TLS Secret, mount it with `defaultMode: 0440`. The files are then owned
by root with group 999 and mode 0440, which PostgreSQL accepts. The default of
0644 makes the server refuse to start.

```yaml
      containers:
        - name: postgres
          env:
            - { name: POSTGRES_SSL_CERT_FILE, value: /etc/postgres-tls/tls.crt }
            - { name: POSTGRES_SSL_KEY_FILE, value: /etc/postgres-tls/tls.key }
          volumeMounts:
            - { name: tls, mountPath: /etc/postgres-tls, readOnly: true }
      volumes:
        - name: tls
          secret: { secretName: postgres-tls, defaultMode: 0440 }
```

Pin the image by digest
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

## Upgrading from the official image

The data format is the same PostgreSQL 18 format, but the official Debian
image and this one link against different glibc versions. Text indexes can
sort differently between glibc versions, so don't point this image at an
existing data directory. Instead, dump and restore, which rebuilds the indexes:

```sh
docker exec old-pg pg_dumpall -U postgres > dump.sql
docker run -d --name pg -e POSTGRES_PASSWORD=... -v newdata:/var/lib/postgresql ghcr.io/jbsiddall/postgres-sunday-roast:18
docker exec -i pg psql -U postgres -h /run/postgresql < dump.sql
```

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
