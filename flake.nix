{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "ChaosMode -- a BattleBit Remastered community server (CommunityServerAPI) with Twitch-driven chaos game modes, redeems and votes. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose.
  #
  # flake-utils would buy exactly one thing here -- eachDefaultSystem -- which is
  # the three-line genAttrs below. In exchange it costs a second lock node in
  # every repo (flake-utils transitively pulls `systems`, so really two), a
  # second upstream that can break one repo and not the others, and a hardcoded
  # system list this repo cannot edit. That list is currently broken: it still
  # contains x86_64-darwin, which now throws (see `systems` below).
  #
  # nixos-unstable is the same channel the author's own NixOS config tracks, so
  # `nix develop` here and `nixos-rebuild` there resolve the same store paths and
  # share one cache.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `...` rather than a closed { self, nixpkgs }: adding a second input later
    # would otherwise fail with "called with unexpected argument 'self'".
    { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with `throw "Nixpkgs 26.11 has dropped support for
      # x86_64-darwin"`. genAttrs is lazy, so plain `nix develop` on Linux would
      # not notice -- it detonates later, on `nix flake check --all-systems`.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather than
      # a system string, because that is what every call site below wants.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # ChaosMode.csproj declares <TargetFramework>net6.0</TargetFramework>, but
      # this shell deliberately ships the .NET 9 SDK, not a .NET 6 one:
      #
      #   * dotnetCorePackages.sdk_6_0 refuses to evaluate at all -- "Refusing to
      #     evaluate package 'dotnet-sdk-6.0.428' ... because it is marked as
      #     insecure". Unblocking it needs `permittedInsecurePackages`, which
      #     forces `import nixpkgs { config = ...; }` and abandons the clean
      #     single-input legacyPackages path this flake is built on. Do not go
      #     there.
      #   * The 9.0 SDK builds a net6.0 project fine (verified: 0 errors), it
      #     just restores the net6.0 reference pack from NuGet and warns that the
      #     target framework is out of support. That warning is correct and is
      #     the real fix: retarget the csproj to net8.0 or net9.0. Until someone
      #     does, DOTNET_ROLL_FORWARD below is what makes the output runnable.
      #
      # Pin the major explicitly. The bare `dotnet-sdk` alias is still 8.0.423,
      # so it is not even the version you would assume, and an alias that moves
      # under you invalidates every obj/ in the fleet on the same afternoon.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: when an attr disappears
      # in a nixpkgs bump, `with` reports a bare undefined identifier with no
      # hint of which set it came from, and the name is not greppable.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        pkgs.dotnet-sdk_9

        # ---- present in every repo in the fleet ----
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # Exactly one entry, and it is load-bearing: the native apphost the SDK
      # emits next to ChaosMode.dll (bin/Debug/net6.0/ChaosMode) is a copy of a
      # prebuilt template binary that nix never patchelfs, and it needs
      # libstdc++.so.6 and libgcc_s.so.1. Without this, launching that
      # executable directly fails with "error while loading shared libraries:
      # libstdc++.so.6: cannot open shared object file". Verified both
      # directions.
      #
      # ICU and OpenSSL are deliberately NOT here even though .NET dlopens both.
      # nixpkgs patches absolute store paths into
      # libSystem.Globalization.Native.so and
      # libSystem.Security.Cryptography.Native.OpenSsl.so, so they resolve with
      # no search path at all -- verified: `new CultureInfo("de-DE")` formats
      # 1234.5 as "1.234,50" (real ICU data, not the invariant fallback) and an
      # HTTPS request completes its TLS handshake, both with only the gcc lib on
      # LD_LIBRARY_PATH. Adding them would be cargo cult.
      #
      # This fixes shared libraries only. The apphost still needs a real ELF
      # interpreter at the FHS path /lib64/ld-linux-x86-64.so.2, which is a host
      # setting -- stock NixOS ships a stub there that exits 127 with "NixOS
      # cannot run dynamically linked executables" unless `environment.ldso` or
      # `programs.nix-ld.enable` is set -- and no project flake can supply it.
      # `dotnet run` / `dotnet bin/.../ChaosMode.dll` go through the store's own
      # patched host and are unaffected; only the emitted apphost cares.
      nativeLibs = pkgs: [
        pkgs.stdenv.cc.cc.lib
      ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Only values that are constants belong here. Anything that must READ an
      # existing value (LD_LIBRARY_PATH), UNSET something (SOURCE_DATE_EPOCH) or
      # touch the work tree goes in the shellHook further down.
      #
      # This attrset is applied to BOTH surfaces -- the dev shell and every
      # `nix run` wrapper -- so a command cannot behave differently depending on
      # how it was invoked.
      envVars = pkgs: {
        # The single most important line in this file. The build produces a
        # net6.0 assembly, and nixpkgs ships no .NET 6 runtime, so launching it
        # dies with "You must install or update .NET to run this application. /
        # Framework: 'Microsoft.NETCore.App', version '6.0.0'" and lists 9.0.18
        # as the only framework found. LatestMajor lets that assembly roll
        # forward onto the 9.0 runtime -- verified, the server then starts and
        # listens on TCP 30001. Do NOT drop this to "silence a warning"; the
        # honest fix is to retarget the csproj, and then this line becomes a
        # harmless no-op.
        DOTNET_ROLL_FORWARD = "LatestMajor";

        # nixpkgs' `dotnet` is a two-line wrapper that exports DOTNET_HOST_PATH
        # and nothing else -- notably NOT DOTNET_ROOT. Anything invoked around it
        # (dotnet-ef, an MSBuild task that shells out, an IDE) therefore sees no
        # SDK at all unless the variable is ambient. Note the path is
        # ${sdk}/share/dotnet, not ${sdk}.
        DOTNET_ROOT = "${pkgs.dotnet-sdk_9}/share/dotnet";

        DOTNET_CLI_TELEMETRY_OPTOUT = "1";
        # `dotnet new` rejects a --nologo flag, which is why this is an env var
        # rather than something the commands below pass.
        DOTNET_NOLOGO = "1";
        # Stops MSBuild leaving persistent worker processes behind, which
        # otherwise pin a stale store path across a nixpkgs bump and produce
        # builds that cannot be explained from the work tree.
        MSBUILDDISABLENODEREUSE = "1";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth. It generates `apps` (so `nix run .#build`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      # Nothing is written twice, so `nix flake show` can never disagree with
      # what `dev-build` actually runs.
      #
      # `test` is absent on purpose: this repo has no test project, no *.sln and
      # no test framework reference. Absence is information -- a stub that echoed
      # "not applicable" would turn the command map into a liar.
      #
      # Every command names the project by absolute path under $REPO_ROOT rather
      # than relying on `dotnet`'s directory probing, so they behave identically
      # from the repo root and from any subdirectory. There is exactly one
      # project here, so there is nothing to disambiguate.
      commands = pkgs: {
        setup = {
          description = "(network) restore NuGet packages for ChaosMode.csproj";
          text = ''dotnet restore "$REPO_ROOT/ChaosMode.csproj" "$@"'';
        };
        build = {
          description = "build ChaosMode (warns that net6.0 is out of support -- expected)";
          text = ''dotnet build --nologo "$REPO_ROOT/ChaosMode.csproj" "$@"'';
        };
        lint = {
          # Honest description: the tree has never been run through
          # `dotnet format`, so this exits 2 today on several hundred
          # pre-existing WHITESPACE findings (verified). That is a real fact
          # about the repo, not a broken flake -- `dev-fmt` is the fix, and it
          # will produce a large diff, so run it deliberately.
          description = "dotnet format --verify-no-changes (non-mutating; today it reports pre-existing whitespace diffs)";
          text = ''dotnet format "$REPO_ROOT/ChaosMode.csproj" --verify-no-changes "$@"'';
        };
        fmt = {
          description = "dotnet format (rewrites files)";
          text = ''dotnet format "$REPO_ROOT/ChaosMode.csproj" "$@"'';
        };
        run = {
          # The server writes appsettings.json, log4net.config and its log file
          # into the CURRENT directory on first start, then binds TCP 30001 (game
          # servers) and 5001 (REST). Anchoring --project means the build is
          # found from anywhere; the generated files still land in the caller's
          # cwd, which is why .gitignore covers them at the repo root.
          description = "start the ChaosMode server (writes appsettings.json into the cwd, binds :30001 and :5001)";
          text = ''dotnet run --project "$REPO_ROOT/ChaosMode.csproj" "$@"'';
        };
      };

      # ======================================================================
      # GENERIC MACHINERY -- byte-identical across the fleet, do not edit
      # ======================================================================

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $REPO_ROOT. `nix run` and `nix develop` both start in
      # whatever directory they were invoked from, so a bare relative path
      # silently resolves against the wrong tree as soon as an agent works from a
      # subdirectory. Note we do NOT cd there: commands act on the caller's cwd
      # on purpose.
      rootPreamble = ''
        REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        export REPO_ROOT
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      wrappers =
        pkgs:
        lib.mapAttrs (
          name: cmd:
          pkgs.writeShellApplication {
            name = "dev-${name}";
            runtimeInputs = toolchain pkgs;
            runtimeEnv = envVars pkgs;
            meta.description = cmd.description;
            text = ''
              ${rootPreamble}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      helpFor =
        pkgs:
        let
          cmds = commands pkgs;
          names = lib.attrNames cmds;
          width = lib.foldl' (a: n: lib.max a (builtins.stringLength n)) 0 names;
          pad = n: n + lib.concatStrings (lib.genList (_: " ") (width - builtins.stringLength n));
          line = n: c: "  dev-${pad n}  ${c.description}";
        in
        pkgs.writeShellApplication {
          name = "dev-help";
          meta.description = "print this repo's command map (works offline)";
          text = ''
            cat <<'EOF'
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList line cmds)}
            EOF
          '';
        };
    in
    {
      # `nix flake show` -- the discovery entrypoint, and deliberately the whole
      # machine-facing contract: every app carries a meta.description, which
      # `nix flake show` prints inline and `nix flake show --json` exposes at
      # .apps.<system>.<name>.description. Pure evaluation, so an agent gets the
      # entire command map in one cheap call without reading a README.
      #
      # Do NOT invent a top-level output for this (`agentManifest` ...). Nix
      # answers with `warning: unknown flake output '<name>'` on every single
      # `nix flake check`, forever.
      #
      # There is no `packages` output on purpose: a real derivation would mean
      # nixifying the NuGet graph (CommunityServerAPI, log4net, six
      # Microsoft.Extensions packages) with a fetch-deps lock file. Restore is
      # left to NuGet, in ~/.nuget, and this flake does not pretend otherwise.
      apps = forAllSystems (
        pkgs:
        lib.mapAttrs (name: cmd: {
          type = "app";
          program = "${(wrappers pkgs).${name}}/bin/dev-${name}";
          meta.description = cmd.description;
        }) (commands pkgs)
      );

      # `nix develop` -- the toolchain, plus a dev-<verb> for every app.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];

          env = envVars pkgs;

          # Some native build steps compile at -O0, where glibc's
          # _FORTIFY_SOURCE becomes a hard error instead of a warning.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any zip or nupkg packed in here then dies with "ZIP
            # does not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. In particular no `dotnet
            # restore`: bootstrapping in the hook makes a cold
            # `nix develop -c dev-build` start downloading before it runs
            # anything, on EVERY invocation, and fail outright in a sandbox with
            # no network. That is what `dev-setup` is for, and its description
            # says "(network)" so an agent knows not to retry it offline.
            #
            # Note `dotnet` needs a writable $HOME for ~/.nuget and ~/.dotnet.
            # Fine interactively; in a sandboxed CI, export one first.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both), and do not use [ -t 1 ]: it
            # leaks the moment an agent harness allocates a pty. >&2 is the
            # second layer.
            case $- in
              *i*) echo "ChaosMode dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction. It realises the toolchain
      # closure (so a typo'd or currently-broken attr fails here) and builds
      # every wrapper, which runs shellcheck over every command text. NEVER add
      # a check that always passes: an agent reads "all checks passed!" as a
      # signal, and a fake check makes `nix flake check` a liar. A real build
      # check is not possible here -- `dotnet restore` needs the network, which
      # the nix sandbox correctly denies.
      checks = forAllSystems (pkgs: {
        toolchain =
          pkgs.runCommand "toolchain-check"
            {
              nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs);
            }
            ''
              for verb in ${lib.escapeShellArgs (lib.attrNames (commands pkgs))}; do
                command -v "dev-$verb" > /dev/null || {
                  echo "dev-$verb is not on PATH" >&2
                  exit 1
                }
              done
              touch "$out"
            '';
      });

      # `nix fmt` -- formats the *Nix* in this repo; project code is `dev-fmt`.
      # nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because bare
      # nixfmt tries to parse every path handed to it and fails on non-Nix files.
      # This file ships already formatted, so `nix fmt` is a no-op rather than a
      # diff.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
