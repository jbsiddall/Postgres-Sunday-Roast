{
  description = "PostgreSQL 18 container image with 90+ extensions, built with Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      withExtensions = pkgs.postgresql_18.withPackages (ps: with ps; [
        # Scheduling, incremental views, analytics, vectors and geospatial.
        pg_cron pg_ivm pg_duckdb pgvector pgvectorscale postgis pgrouting h3-pg
        # Procedural languages. nixpkgs dropped plv8 (insecure NodeJS 20), so
        # JavaScript comes from PL/JS.
        plpython3 (ps.callPackage ./pljs.nix { })
        # Operations: partitioning, online repack, hints, hypothetical indexes,
        # background jobs, safe updates, PL/pgSQL linting and unit tests.
        pg_partman pg_repack pg_hint_plan hypopg pg_background pg_safeupdate
        plpgsql_check pgtap
        # Search and similarity.
        rum pg_bigm pg_similarity
        # Data types: UUIDv7, IP ranges, semver, rationals, HyperLogLog,
        # roaring bitmaps, temporal tables and SQL:2011 periods.
        pg_uuidv7 ip4r pg-semver pg_rational pg_hll pg_roaringbitmap
        temporal_tables periods
        # APIs, messaging and integration.
        pgsql-http pgjwt pg_graphql pgmq pg_csv tds_fdw wal2json
        # Security and privacy.
        pgsodium anonymizer
        # Graphs.
        age
      ]);

      # PostGIS links GDAL, whose Python bindings keep numpy, BLAS, LAPACK and
      # gfortran (about 230 MB) in the closure. PostgreSQL only loads the C
      # library, so numpy is swapped for an empty path without rebuilding.
      numpy = pkgs.python3Packages.numpy;
      postgres = pkgs.replaceDependencies {
        drv = withExtensions;
        replacements = [{
          oldDependency = numpy;
          newDependency = pkgs.runCommand numpy.name { } "mkdir $out";
        }];
        verbose = false;
      };

      locales = pkgs.glibcLocales.override { allLocales = false; locales = [ "en_US.UTF-8/UTF-8" "C.UTF-8/UTF-8" ]; };

      # PgBouncer's systemd integration adds a large, unused runtime dependency.
      pgbouncer = pkgs.pgbouncer.overrideAttrs (a: {
        buildInputs = builtins.filter (p: (p.pname or "") != "systemd") a.buildInputs;
        configureFlags = (a.configureFlags or []) ++ [ "--without-systemd" ];
      });
      postgrest = pkgs.lib.getBin pkgs.postgrest;

      nss = pkgs.runCommand "postgres-nss" { } ''
        mkdir -p $out/etc
        echo 'root:x:0:0:root:/root:/bin/bash' > $out/etc/passwd
        echo 'postgres:x:999:999:PostgreSQL:/var/lib/postgresql:/bin/bash' >> $out/etc/passwd
        echo 'root:x:0:' > $out/etc/group
        echo 'postgres:x:999:' >> $out/etc/group
        echo 'hosts: files dns' > $out/etc/nsswitch.conf
      '';

      entrypoint = pkgs.writeShellApplication {
        name = "docker-entrypoint";
        runtimeInputs = [ postgres pgbouncer postgrest pkgs.pgweb pkgs.s6 pkgs.coreutils pkgs.gzip pkgs.openssl ];
        text = builtins.readFile ./entrypoint.sh;
      };

      image = pkgs.dockerTools.buildLayeredImage {
        name = "postgres-sunday-roast";
        tag = pkgs.postgresql_18.version;
        contents = [ postgres pgbouncer postgrest pkgs.pgweb pkgs.s6 entrypoint nss locales pkgs.bashInteractive pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.gzip pkgs.openssl pkgs.tzdata pkgs.cacert ];
        fakeRootCommands = ''
          mkdir -p ./tmp ./run/postgresql ./run/psr-services ./var/lib/postgresql ./docker-entrypoint-initdb.d ./usr/bin
          # Init scripts often start with #!/usr/bin/env bash.
          ln -s /bin/env ./usr/bin/env
          chmod 1777 ./tmp
          chown 999:999 ./run/postgresql ./run/psr-services ./var/lib/postgresql
          chmod 2775 ./run/postgresql
        '';
        config = {
          User = "999:999";
          Entrypoint = [ "/bin/docker-entrypoint" ];
          # s6 stops the tree; postgres receives SIGINT for a fast shutdown.
          StopSignal = "SIGTERM";
          ExposedPorts."5432/tcp" = { };
          ExposedPorts."6432/tcp" = { };
          ExposedPorts."3000/tcp" = { };
          ExposedPorts."8081/tcp" = { };
          Volumes."/var/lib/postgresql" = { };
          Labels = {
            "org.opencontainers.image.source" = "https://github.com/jbsiddall/Postgres-Sunday-Roast";
            "org.opencontainers.image.description" = "PostgreSQL ${pkgs.postgresql_18.version} with 90+ extensions, built with Nix";
            "org.opencontainers.image.licenses" = "Apache-2.0";
          };
          Env = [
            "PGDATA=/var/lib/postgresql/18/docker"
            "LANG=en_US.UTF-8"
            "LOCALE_ARCHIVE=${locales}/lib/locale/locale-archive"
            "TZDIR=${pkgs.tzdata}/share/zoneinfo"
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            "PATH=/bin"
          ];
        };
      };
    in {
      packages.${system} = {
        default = image;
        inherit postgres pgbouncer postgrest;
        inherit (pkgs) pgweb s6;
      };
    };
}
