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
