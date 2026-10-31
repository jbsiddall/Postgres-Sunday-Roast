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

### PostgreSQL processes are named `.postgres-wrapp`

nixpkgs wraps the `postgres` binary, so `/proc/<pid>/comm` for the postmaster
and every backend is `.postgres-wrapp`, the wrapped name cut to 15 bytes. A
process filter that matches `comm` against `postgres` silently selects
nothing. Observed in the 18.6 image built from nixpkgs 1c89083e, 2026-10-31,
with podman: 11 processes, all `.postgres-wrapp`. `pgbouncer`, `postgrest`,
`pgweb` and `s6-svscan` keep their own names.
