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
| `POSTGRES_PASSWORD` | required on first start | Password of `POSTGRES_USER`. |
| `POSTGRES_USER` | `postgres` | Superuser created on first start. |
| `POSTGRES_DB` | `$POSTGRES_USER` | Database created on first start. |
| `POSTGRES_INITDB_ARGS` | none | Extra `initdb` flags, e.g. `--data-checksums`. |
| `PGDATA` | `/var/lib/postgresql/18/data` | Data directory. Mount a volume at `/var/lib/postgresql`. |
| `POSTGRES_SSL_CERT_FILE`, `POSTGRES_SSL_KEY_FILE` | self-signed in `$PGDATA` | Use your own certificate, e.g. from a Kubernetes secret. |
| `POSTGRES_SSL_CN` | `postgres` | Common name of the generated certificate. |
| `POSTGRES_SHARED_PRELOAD_LIBRARIES` | `pg_stat_statements,pg_cron,pg_ivm,pg_duckdb` | Change what is preloaded. |
| `POSTGRES_CRON_DATABASE` | `postgres` | Database that holds `pg_cron`'s tables. |

`POSTGRES_PASSWORD`, `POSTGRES_USER`, `POSTGRES_DB` and `POSTGRES_INITDB_ARGS`
can instead be read from a file, such as a Docker or Kubernetes secret, by
setting `POSTGRES_PASSWORD_FILE` and so on. Setting both forms is an error.

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

Stopping: the image's stop signal is `SIGINT`, so `docker stop` disconnects
clients and shuts down cleanly instead of waiting for idle connections until
the server is killed.

Authentication: local socket connections are trusted, and every TCP connection
must use a password (SCRAM-SHA-256). SSL is always on; to force it for TCP,
change `host` to `hostssl` in `pg_hba.conf`.

User: the server runs as uid and gid 999. If a volume was created for a
different uid, `chown -R 999:999` it first.

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
the volume at `/var/lib/postgresql`.

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

The image is 714 MB uncompressed, which is 230 MB to download. The official
`postgres:18` image is 464 MB and includes none of these extensions. Nix
copies only runtime files into the image, so compilers and build
dependencies never end up in it. The biggest parts are Python (137 MB, for
PL/Python), DuckDB (69 MB), GDAL and PROJ (for PostGIS) and ICU.

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
docker run -d --name smoke -e POSTGRES_PASSWORD=smoke-only -e POSTGRES_DB=app \
  -v "$PWD/tests/initdb:/docker-entrypoint-initdb.d:ro" postgres-sunday-roast:18.6
tests/smoke.sh smoke docker
```

The smoke test checks SSL, the preloaded libraries, the init scripts and
`pg_cron`, then creates every available extension. CI runs the same test on
every pull request and pushes the image to GHCR from `main`.

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
