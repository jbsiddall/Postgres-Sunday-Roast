# PL/JS: JavaScript functions on QuickJS, from the plv8 project. It replaces
# plv8, which nixpkgs removed because its V8 build needs the end-of-life NodeJS 20.
{ fetchFromGitHub, lib, postgresql, postgresqlBuildExtension }:

postgresqlBuildExtension (finalAttrs: {
  pname = "pljs";
  version = "1.0.5";

  src = fetchFromGitHub {
    owner = "plv8";
    repo = "pljs";
    tag = "v${finalAttrs.version}";
    fetchSubmodules = true;
    hash = "sha256-9wLDiUDusiN9JvDbYlrKik1ZmymhOek29tMHUg3FiNg=";
  };

  # The Makefile patches QuickJS only when it clones the submodule itself.
  postPatch = ''
    for p in patches/*; do patch -p1 < "$p"; done
  '';

  # QuickJS hard-codes gcc and gcc-ar; nixpkgs builds Postgres extensions with clang.
  makeFlags = [ "CC=cc" "AR=ar" "CONFIG_LTO=" ];

  meta = {
    description = "JavaScript procedural language for PostgreSQL, on QuickJS";
    homepage = "https://github.com/plv8/pljs";
    license = lib.licenses.postgresql;
    platforms = postgresql.meta.platforms;
  };
})
