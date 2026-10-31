# Domain knowledge

## Bash

### The image's bash has no `compgen`

`writeShellApplication` runs scripts with nixpkgs `runtimeShellPackage`, a
non-interactive bash built without programmable completion. `compgen` is
missing (exit 127). Inside a loop such as `for var in $(compgen -e)`, the
error only reaches stderr and the loop runs zero times, so the script carries
on with nothing. The interactive bash at `/bin/bash` does have it. Use
`${!PREFIX@}` to list variables instead. Observed with bash 5.3.20, nixpkgs
1c89083e, 2026-10-31. Get that bash with
`nix build --no-link --print-out-paths --inputs-from . "nixpkgs#runtimeShellPackage^out"`.

## Nix

### Closure queries need explicit runtime outputs

With Nix 2.34.7 and nixpkgs 1c89083e, `nix path-info -r .#s6` selects
`meta.outputsToInstall = [ "out" "man" ]`, not just the `out` path used by
the image. The image build does not realise `man`; querying a missing output
fails with `path '…-s6-2.15.1.0-man' is not valid` even when Nix announces
that it can fetch it. Use `'.#s6^out'` and explicitly select PostgREST's
`bin` output when auditing the service runtime closures. Keep the Nix query
in a separate assignment before grep so query failures stop CI instead of
silently passing as an empty closure. Observed 2026-10-31.

### PostgreSQL processes are named `.postgres-wrapp`

nixpkgs wraps the `postgres` binary, so `/proc/<pid>/comm` for the postmaster
and every backend is `.postgres-wrapp`, the wrapped name cut to 15 bytes. A
process filter that matches `comm` against `postgres` silently selects
nothing. Observed in the 18.6 image built from nixpkgs 1c89083e, 2026-10-31,
with podman: 11 processes, all `.postgres-wrapp`. `pgbouncer`, `postgrest`,
`pgweb` and `s6-svscan` keep their own names.

## PostgREST

### Anonymous rejection does not establish readiness

PostgREST 14.16 authenticates before checking its schema cache or using the
database. With no anonymous role, an anonymous request returns 401 even while
a valid JWT gets 503 because the schema cache is still loading or the database
connection is unavailable. The smoke test's anonymous check silently treated
this as readiness, then sampled the authenticated request only once. Retry
unavailable responses, but fail immediately on JWT or permission errors. The
admin server's `/ready` endpoint also checks readiness, but its listener is
disabled by default in this image. Confirmed from the pinned source and a
local run without a database, 2026-10-31. See
[request ordering](https://github.com/PostgREST/postgrest/blob/v14.16/src/PostgREST/App.hs#L121-L170)
and [error statuses](https://github.com/PostgREST/postgrest/blob/v14.16/src/PostgREST/Error.hs#L693-L739).

## Kubernetes

### fsGroup broadens PostgreSQL directory permissions

Read on 2026-10-31: kubelet v1.35.0's
[volume ownership handling](https://raw.githubusercontent.com/kubernetes/kubernetes/v1.35.0/pkg/volume/volume_linux.go)
treats a volume root without setgid as an `OnRootMismatch`, even when its
group already matches `fsGroup`. For a writable volume, recursion ORs group
rwx and setgid into every directory, changing PGDATA mode 0700 or 0750 to
2770. The official PostgreSQL 18
[Dockerfile at e00e1bd](https://github.com/docker-library/postgres/blob/e00e1bd34ec5c8a8e7ad89b273b3d42efaf6d5bc/18/trixie/Dockerfile)
creates `/var/lib/postgresql` as 1777, without setgid. The 2026-10-31 review
reproduced PostgreSQL 18.6 refusing mode 2770 with "invalid permissions" and
requiring 0700 or 0750; this was a local permission reproduction, not a
Kubernetes deployment test.

Read on 2026-10-31: the same kubelet v1.35.0 implementation ORs 0660 into
regular files on writable volumes, turning a 0600 TLS key into 0660. A
root-owned 0640 key also becomes 0660. The
[PostgreSQL 18 SSL rules](https://www.postgresql.org/docs/18/ssl-tcp.html)
allow no group/world access on a database-owned key, or group read access on a
root-owned key, but never group write. Resetting only PGDATA to 0700 leaves
those broadened key modes unchanged. The 2026-10-31 review reproduced this
locally with PostgreSQL 18.6 and a real key: 0700/0600 started, 0700/0660
failed with "has group or world access", and restoring only the key to 0600
started again. This applied the source-derived mask, not a live kubelet mount.

The v1.35.0
[emptyDir implementation](https://raw.githubusercontent.com/kubernetes/kubernetes/v1.35.0/pkg/volume/emptydir/empty_dir.go)
creates default directory-backed volumes with mode 0777 and corrects
restrictive umasks with chmod. Read on 2026-10-31.

## PostgreSQL

### Official PostgreSQL 18 image layout and initdb

Read on 2026-10-31: official
[Dockerfile commit e00e1bd34ec5c8a8e7ad89b273b3d42efaf6d5bc](https://github.com/docker-library/postgres/blob/e00e1bd34ec5c8a8e7ad89b273b3d42efaf6d5bc/18/trixie/Dockerfile)
sets `PGDATA=/var/lib/postgresql/18/docker`, declares
`VOLUME /var/lib/postgresql`, and creates `postgres` uid/gid 999.
Its [entrypoint at that commit](https://github.com/docker-library/postgres/blob/e00e1bd34ec5c8a8e7ad89b273b3d42efaf6d5bc/18/trixie/docker-entrypoint.sh)
invokes initdb with username, password file, user `POSTGRES_INITDB_ARGS`
and optional `--waldir`. It supplies no default checksum-disabling flag.
Before checking whether a cluster already exists, it calls
`docker_create_db_directories`, which runs `chmod 00700 "$PGDATA" || :`.
Existing 0750 directories are reset to 0700 as well as 2770 directories.
The [PostgreSQL 18 initdb reference](https://www.postgresql.org/docs/18/app-initdb.html)
says checksums are enabled by default. These are source observations, not a
container test.

### Registry and glibc versions

Queried the Docker registry on 2026-10-31: `postgres:18` resolves to index
`sha256:979bccfde35445db618c65107d27d08c6c21339d8dc3ad4c830c6633947be0e4`.
Its linux/amd64 manifest is
`sha256:f4b419e350fd98d4a8429603295208976dea4c8fb8326d818d346d3e29f1db6f`,
annotated version 18.6, source revision e00e1bd and creation time
2026-10-28T01:30:07Z. Reading `var/lib/dpkg/status` from its layers found
`libc6 2.41-12+deb13u4` (amd64), also listed by
[Debian's trixie package page](https://packages.debian.org/trixie/libc6).
The locked nixpkgs revision 1c89083e451e891152365b799595cf7790a43325
[defines glibc 2.44](https://github.com/NixOS/nixpkgs/blob/1c89083e451e891152365b799595cf7790a43325/pkgs/development/libraries/glibc/common.nix);
`nix eval --raw --inputs-from . nixpkgs#glibc.version` returned `2.44`
on 2026-10-31.

### WAL segment size is taken from the cluster

Read on 2026-10-31: PostgreSQL 18.6
[ReadControlFile](https://github.com/postgres/postgres/blob/REL_18_6/src/backend/access/transam/xlog.c)
loads `wal_segment_size` from `pg_control` and accepts powers of two
between 1 MB and 1 GB. It does not require the initdb default of 16 MB.
The same function rejects mismatched block sizes, alignment, floating-point
format and float8/int8 pass-by-value settings. The
[control header](https://github.com/postgres/postgres/blob/REL_18_6/src/include/catalog/pg_control.h)
labels `float8ByVal` as applying to float8 and int8; the
[timestamp header](https://github.com/postgres/postgres/blob/REL_18_6/src/include/datatype/timestamp.h)
defines timestamps as int64.

## Unverified

[unverified: no live Kubernetes deployment check] Starting this image as
999:999 with a read-only root and default `emptyDir: {}` mounts at
`/run/postgresql`, `/run/psr-services` and `/tmp` remains an inference from
kubelet v1.35.0 source and the image's startup writes, read on 2026-10-31.

[unverified: storage driver not specified or exercised] A fresh filesystem PVC
may present a root-owned mount; its ownership and modes depend on the storage
provisioner. Whether a particular PVC is writable by 999:999 without preparation
is not established by the image's directory ownership or the emptyDir source.

[unverified: no container runtime in the editing environment] The official
volume round trip and whether this exact glibc change logs a collation-version
warning await `tests/official-volume.sh` on a Docker or podman host. Different
version numbers alone do not establish which text comparisons changed.
