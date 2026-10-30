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
