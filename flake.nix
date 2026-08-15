{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "ChaosMode -- a BattleBit Remastered community server (CommunityServerAPI) whose game modes, redeems and votes are driven by Twitch events delivered to its REST endpoint. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose: the machinery below brings its own
  # `systems` list and its own genAttrs-based forAllSystems, so there is
  # nothing for a flake-utils to add. flake.lock therefore carries exactly one
  # input node, and there is exactly one upstream that can break this repo.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `self` is mandatory: the machinery anchors every verb on it. `...` rather
    # than a closed { self, nixpkgs }: so adding a second input later does not
    # fail with "called with unexpected argument".
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # ======================================================================
      # PER-REPO BLOCK 5 -- the name in the interactive dev-shell banner
      # ======================================================================
      repoName = "ChaosMode";

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # ChaosMode.csproj declares <TargetFramework>net6.0</TargetFramework>, but
      # this shell deliberately ships the .NET 9 SDK, not a .NET 6 one:
      #
      #   * dotnetCorePackages.sdk_6_0 throws as soon as its derivation is
      #     forced -- "error: Refusing to evaluate package
      #     'dotnet-sdk-6.0.428' ... because it is marked as insecure"
      #     (measured against this lock). Unblocking it needs
      #     `permittedInsecurePackages`, which forces
      #     `import nixpkgs { config = ...; }` and abandons the single-input
      #     legacyPackages path the machinery below is built on.
      #   * The 9.0 SDK builds this net6.0 project (measured: `dev-build` ends
      #     in "0 Error(s)"), it just warns NETSDK1138 that net6.0 is out of
      #     support. That warning is correct and the real fix is to retarget
      #     the csproj; until someone does, DOTNET_ROLL_FORWARD below is what
      #     makes the output runnable.
      #
      # Pin the major explicitly: under this lock the bare `dotnet-sdk` alias is
      # dotnet-sdk-wrapped-8.0.423, not 9, so it is not even the version you
      # would assume.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: when an attr disappears
      # in a nixpkgs bump, `with` reports a bare undefined identifier with no
      # hint of which set it came from, and the name is not greppable.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        pkgs.dotnet-sdk_9

        # ---- general-purpose, for the human and the agent at the prompt ----
        # No verb below invokes any of these; they are here so an interactive
        # shell is not missing the obvious. In particular the anchor in the
        # machinery below needs no git -- it compares flake.nix with bash's own
        # `$(<file)`.
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # Exactly one entry, and it is load-bearing: the native apphost the SDK
      # emits next to ChaosMode.dll (bin/Debug/net6.0/ChaosMode) is emitted by
      # the SDK at build time and never goes through nix's patchelf. Measured
      # on the built output: `ldd` resolves libstdc++.so.6 and libgcc_s.so.1
      # out of the gcc-lib store path this list puts on LD_LIBRARY_PATH, and
      # with LD_LIBRARY_PATH cleared the apphost dies with "error while loading
      # shared libraries: libstdc++.so.6: cannot open shared object file".
      #
      # ICU and OpenSSL are deliberately NOT here even though .NET dlopens
      # both. nixpkgs patches absolute store paths into the runtime's own
      # native shims -- `strings` finds .../icu4c-78.3/lib/libicuuc.so inside
      # libSystem.Globalization.Native.so and .../openssl-3.6.3/lib/libssl.so
      # inside libSystem.Security.Cryptography.Native.OpenSsl.so -- so they
      # resolve with no search path at all. Adding them would be cargo cult.
      #
      # This fixes shared libraries only. The apphost also asks for its ELF
      # interpreter by the FHS path /lib64/ld-linux-x86-64.so.2 (measured with
      # `patchelf --print-interpreter`), and no project flake can supply that
      # -- it is a host setting; the machine this was checked on has NixOS's
      # `environment.ldso` pointing at a store glibc, and a host without it
      # cannot launch the apphost at all. `dotnet run` and
      # `dotnet bin/Debug/net6.0/ChaosMode.dll` are unaffected: the store's own
      # `dotnet` host asks for a store interpreter instead. Only the emitted
      # apphost cares.
      nativeLibs = pkgs: [
        pkgs.stdenv.cc.cc.lib
      ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Constants only. Anything that must READ an existing value
      # (LD_LIBRARY_PATH) or UNSET something (SOURCE_DATE_EPOCH) is the
      # machinery's business, not this attrset's. Applied to BOTH surfaces --
      # the dev shell and every wrapper -- so a verb cannot behave differently
      # depending on how it was invoked.
      envVars = pkgs: {
        # The single most important line in this file. The build produces a
        # net6.0 assembly and this SDK ships exactly one shared runtime
        # (share/dotnet/shared/Microsoft.NETCore.App contains only 9.0.18), so
        # without this the assembly dies with "You must install or update .NET
        # to run this application. ... Framework: 'Microsoft.NETCore.App',
        # version '6.0.0'" listing 9.0.18 as the only framework found.
        # LatestMajor rolls it forward onto 9.0.18 -- measured, both
        # directions. Do NOT drop this to "silence a warning"; the honest fix
        # is to retarget the csproj, after which this line is a no-op.
        DOTNET_ROLL_FORWARD = "LatestMajor";

        # nixpkgs' `dotnet` on PATH is a three-line wrapper script (shebang,
        # one export, one exec) that sets DOTNET_HOST_PATH and nothing else:
        # the string DOTNET_ROOT does not occur in it at all. So anything that
        # locates an SDK by reading DOTNET_ROOT gets nothing unless this line
        # supplies it. Note the SDK lives at <sdk>/share/dotnet, not <sdk>
        # itself -- that is where sdk/, shared/ and packs/ actually are.
        DOTNET_ROOT = "${pkgs.dotnet-sdk_9}/share/dotnet";

        DOTNET_CLI_TELEMETRY_OPTOUT = "1";
        # An env var rather than a flag the commands pass, because `dotnet new`
        # rejects one: `dotnet new --nologo` answers "No templates or
        # subcommands found matching: '--nologo'." and exits non-zero.
        DOTNET_NOLOGO = "1";
        # MSBUILDDISABLENODEREUSE used to be set here, justified as stopping
        # MSBuild worker processes from outliving the build. That did not
        # reproduce: with node reuse left enabled, `ps` found no MSBuild node
        # after `dev-build` returned. The one process that does linger is
        # Roslyn's VBCSCompiler, which that variable does not control
        # (`dotnet build-server shutdown` does).
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth: it generates `apps` (so `nix run .#build`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      # Nothing is written twice, so `nix flake show` can never disagree with
      # what `dev-build` actually runs.
      #
      # `test` is absent on purpose: there is no test project, no *.sln and no
      # test-framework PackageReference in this tree. Absence is information --
      # a stub that echoed "not applicable" would turn the command map into a
      # liar.
      #
      # There is no `packages` output either (and the machinery below defines
      # the output set, so this repo could not add one without editing the
      # fleet): a real derivation would mean nixifying the NuGet graph -- the
      # csproj has six PackageReferences, CommunityServerAPI, log4net,
      # Microsoft.AspNetCore.Mvc.Core and three Microsoft.Extensions.* -- with a
      # fetch-deps lock file. Restore is left to NuGet under ~/.nuget and this
      # flake does not pretend otherwise.
      #
      # Every verb here writes into the tree it acts on, including the
      # read-only-sounding one: a restore materialises obj/ beside the csproj
      # (project.assets.json, ChaosMode.csproj.nuget.g.props, ...), and
      # `dotnet format --verify-no-changes` pointed at the read-only store
      # snapshot dies with "Unhandled exception: System.Exception: Restore
      # operation failed." So all five call need_writable_checkout first and
      # then cd to $REPO_ROOT. The cd is what keeps `dotnet` from dropping
      # files into the caller's directory; its cost is that a relative path
      # argument is resolved against $REPO_ROOT, so pass absolute paths.
      commands = pkgs: {
        setup = {
          description = "(network) restore NuGet packages for ChaosMode.csproj";
          text = ''
            need_writable_checkout
            cd "$REPO_ROOT"
            dotnet restore "$REPO_ROOT/ChaosMode.csproj" "$@"
          '';
        };
        build = {
          description = "(network on first run) build ChaosMode; warns NETSDK1138 that net6.0 is out of support";
          text = ''
            need_writable_checkout
            cd "$REPO_ROOT"
            dotnet build --nologo "$REPO_ROOT/ChaosMode.csproj" "$@"
          '';
        };
        lint = {
          # Exits 2 today on pre-existing whitespace findings -- 353 of them
          # when this was written, every one `error WHITESPACE`, because the
          # tree has never been run through `dotnet format`. That is a fact
          # about the repo, not a broken flake; `dev-fmt` is the fix and it
          # will produce a large diff, so run it deliberately.
          description = "(network on first run) dotnet format --verify-no-changes; today it exits 2 on pre-existing whitespace findings";
          text = ''
            need_writable_checkout
            cd "$REPO_ROOT"
            dotnet format "$REPO_ROOT/ChaosMode.csproj" --verify-no-changes "$@"
          '';
        };
        fmt = {
          description = "(network on first run) dotnet format -- rewrites the C# sources in place";
          text = ''
            need_writable_checkout
            cd "$REPO_ROOT"
            dotnet format "$REPO_ROOT/ChaosMode.csproj" "$@"
          '';
        };
        run = {
          # Measured on a cold start in an empty directory: the server writes
          # appsettings.json and log4net.config (both .gitignore'd at the repo
          # root) if they are absent, then listens on TCP 30001. It does NOT
          # open the REST port -- StartRest waits for `Server` to be non-null,
          # which only happens once a game server has connected, so nothing is
          # listening on 5001 until then. The log4net config it writes points
          # its FileAppender at `logs\log.txt`, a Windows path that produced no
          # file at all on Linux.
          description = "(network on first run) start the ChaosMode server; writes appsettings.json and log4net.config into the repo root, listens on TCP 30001";
          text = ''
            need_writable_checkout
            cd "$REPO_ROOT"
            dotnet run --project "$REPO_ROOT/ChaosMode.csproj" "$@"
          '';
        };
      };

      # ======================================================================
      # PER-REPO BLOCK 6 -- checks beyond the canonical two
      # ======================================================================
      # Empty, and that is a measured conclusion rather than laziness: every
      # verb this repo has runs through MSBuild, MSBuild needs a NuGet restore,
      # and a restore needs the network, which the nix build sandbox denies
      # (measured: a sandboxed `dotnet restore` of this csproj fails with
      # NU1301 "Unable to load the service index for source
      # https://api.nuget.org/v3/index.json"). A verb-level anchoring probe of
      # the kind INTERFACE.md recommends therefore cannot run here. NEVER
      # replace this with a check that always passes.
      extraChecks = _: { };

      # >>>>> BEGIN CANONICAL MACHINERY v1 <<<<<
      # ======================================================================
      # Everything from the BEGIN sentinel above to the END sentinel on the last
      # line of this file is fleet-canonical text: the same bytes in every repo
      # that carries this flake style. That is a checkable claim, not a boast --
      #
      #   sed -n '/BEGIN CANONICAL MACHINERY v1/,$p' flake.nix | sha256sum
      #
      # prints the same digest in every repo, or one of them has been edited.
      # (`,$p`, not a range ending on the END sentinel: a range whose closing
      # pattern were spelled out here would terminate on this very comment.)
      # Nothing here names a repository, a language, a tool or a project file.
      # If you find such a name below, it is contamination: the fix is to move
      # it into the per-repo section above, never to special-case it here.
      #
      # This region READS exactly these names from the per-repo section:
      #   nixpkgs  self  lib  repoName  toolchain  nativeLibs  envVars
      #   commands  extraChecks
      # and DEFINES exactly these:
      #   systems  forAllSystems  ldPreamble  rootPreamble  guardPreamble
      #   wrappers  helpFor  anchorCheck
      # plus the four flake outputs apps / devShells / checks / formatter.
      # Anything else in scope is invisible to it. The types of those eight
      # inputs, and the shell variables this region exports into command texts,
      # are specified in INTERFACE.md, which travels with this block.
      #
      # To change behaviour here you change it in every repo at once and bump
      # the version in both sentinels. A local edit is a bug by construction:
      # the digest above stops matching, and -- because rootPreamble anchors on
      # flake.nix byte-identity -- an edited working tree also stops being
      # recognised by wrappers built from the previous revision.
      # ======================================================================

      # ---- systems policy: decided once for the whole fleet ----
      #
      # Read this list as "evaluated on three, built on one". That is what was
      # measured, and it is all it means:
      #   * `nix flake check --all-systems` passes, so every output attribute
      #     below EVALUATES on all three systems.
      #   * only x86_64-linux has ever been BUILT. The machine this was verified
      #     on has no aarch64 emulation -- no binfmt handler, and `extra-
      #     platforms` is x86-only -- so aarch64 cannot be built there at all.
      # It is not a statement that anything works on aarch64. Do not upgrade it
      # into one in a README.
      #
      # Evaluating all three is still worth its seconds, because the failure it
      # catches is an eval-time failure: a `pkgs.<attr>` that exists on Linux
      # and not on darwin (`stdenv.cc.cc.lib` is the usual one) throws during
      # evaluation, and `nix flake check` without --all-systems checks only the
      # current system and sails straight past it.
      #
      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with a `throw`. genAttrs is lazy, so plain `nix develop`
      # on Linux would not notice -- it detonates later, on the --all-systems
      # run this policy requires. Add it back only against a separate
      # nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather
      # than a system string, because that is what every call site wants, and
      # keeps the system list in this file rather than in a second input's
      # hardcoded copy of it.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      #
      # `&&` short-circuits in Nix, so on darwin `nativeLibs pkgs` is never
      # forced. That is load-bearing for the systems policy above: it is what
      # lets a repo list Linux-only attrs in nativeLibs and still evaluate on
      # aarch64-darwin. Do not reorder the two operands.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $SRC_ROOT and $REPO_ROOT. `nix run` and `nix develop`
      # both start in whatever directory they were invoked from, and no verb may
      # act on that directory -- these two are what it acts on instead.
      #
      # $SRC_ROOT is this flake's own source, snapshotted into the store when
      # the flake was evaluated. It is the one anchor that is always available:
      # `nix run /path/to/repo#lint` tells the running program nothing whatever
      # about /path/to/repo (flake refs are location-independent by design, and
      # there is no $FLAKE_DIR to read), so without `self` a wrapper invoked
      # that way has literally no way to name the repo it belongs to. Two
      # limitations worth knowing: it is read-only, being a store path, and in a
      # git checkout it contains only TRACKED files.
      #
      # $REPO_ROOT is the writable checkout when the caller is standing in one,
      # and $SRC_ROOT when they are not. Three things this deliberately is NOT:
      #
      #   * NOT `pwd`. A fallback to the caller's directory is how `fmt`
      #     rewrites a stranger's source tree and how `lint` prints "all checks
      #     passed" having read none of this repo.
      #   * NOT `git rev-parse --show-toplevel`. Run from inside some OTHER git
      #     repo it cheerfully answers with THAT repo's top level. It also needs
      #     git on PATH and a .git directory, so it fails on an export and in
      #     any wrapper whose toolchain omits git.
      #   * NOT an inherited $REPO_ROOT from the environment. The dev shell
      #     EXPORTS this variable, so honouring it would mean that running
      #     `nix run /path/to/B#fmt` from inside repo A's dev shell points B's
      #     formatter at A. An explicit path argument is how a caller overrides
      #     a verb's target; an ambient variable is how they do it by accident.
      #
      # Instead: walk up from $PWD and take the first ancestor that IS this
      # repo, proved by carrying a byte-identical flake.nix. A single tracked
      # filename, a marker directory, or a set of them is not proof -- sibling
      # repos in a fleet share those, and a decoy can be built to carry any list
      # of names you care to publish. The whole flake.nix is what distinguishes
      # repos, because description, toolchain and command map all differ, so the
      # whole flake.nix is what gets compared. Compared with bash's own
      # `$(<file)` rather than cmp or sha256sum, so the check depends on no
      # package at all -- pure builtins, correct even in a wrapper whose PATH
      # carries nothing but the repo's own toolchain.
      #
      # Consequence worth knowing: edit flake.nix and the dev-* wrappers in an
      # already-open `nix develop` stop recognising the tree, because they were
      # built from the previous flake.nix. That is a stale shell telling you so
      # -- re-enter it. `nix run` re-evaluates every time and never sees this.
      rootPreamble = ''
        SRC_ROOT=${lib.escapeShellArg "${self}"}
        export SRC_ROOT

        _dev_find_root() {
          local dir ref
          ref=$(<"$SRC_ROOT/flake.nix") || return 1
          dir=$(
            unset CDPATH
            cd -P -- "''${1:-.}" 2>/dev/null && pwd
          ) || return 1
          while [ -n "$dir" ]; do
            if [ -f "$dir/flake.nix" ] && [ "$(<"$dir/flake.nix")" = "$ref" ]; then
              printf '%s\n' "$dir"
              return 0
            fi
            dir=''${dir%/*}
          done
          return 1
        }

        REPO_ROOT="$(_dev_find_root "$PWD" || printf '%s\n' "$SRC_ROOT")"
        export REPO_ROOT
      '';

      # Wrappers only, not the shellHook -- an interactive shell has no business
      # carrying this function around. Any command text that writes files calls
      # it first, and it is the reason a mutating verb can fail loudly instead
      # of falling back to "well, the cwd then".
      #
      # The test is $REPO_ROOT != $SRC_ROOT, i.e. "rootPreamble found a real
      # checkout", not a permission or a store-path-prefix test. Both of those
      # answer a narrower question: a checkout may be read-only for unrelated
      # reasons, and a store path is not the only tree we must refuse to write.
      guardPreamble = ''
        need_writable_checkout() {
          if [ "$REPO_ROOT" != "$SRC_ROOT" ]; then
            return 0
          fi
          echo "''${0##*/}: this command rewrites files, so it needs a writable" >&2
          echo "checkout of this repo -- and standing in $PWD there is none: no" >&2
          echo "parent directory carries this flake's flake.nix. The only tree in" >&2
          echo "reach is the read-only store snapshot $SRC_ROOT, and rewriting" >&2
          echo "$PWD instead is exactly the bug this guard exists to prevent." >&2
          echo "cd into the repo (or \`nix develop\` it), or pass an explicit path." >&2
          exit 1
        }
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      #
      # writeShellApplication, not writeShellScriptBin: it runs shellcheck at
      # BUILD time and sets `set -euo pipefail`, so an unquoted $@ or a silently
      # ignored failure is a `nix flake check` failure rather than a surprise in
      # front of an agent.
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
              ${guardPreamble}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      # `dev-help` is generated from the same attrset as everything else, so it
      # cannot describe a verb that does not exist or miss one that does. No
      # runtimeInputs: printing the map must work with nothing installed.
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

      # The regression gate for rootPreamble and guardPreamble, which are the
      # two pieces of this flake that can silently damage a tree that is not
      # this repo. It tests the MECHANISM, not any verb, which is precisely what
      # makes it fleet-generic: it needs to know nothing about what this repo
      # does, only that the anchor resolves and the guard refuses.
      #
      # The decoy is a real directory carrying a real flake.nix that differs.
      # Marker-file anchors pass a decoy like this -- that is the whole point of
      # the probe -- and so does any anchor that trusts `pwd`. Probe 2 is the
      # other half, and without it a guard that refused everything would score a
      # perfect pass: a tree that IS byte-identical must still be adopted, or
      # every mutating verb in the repo is dead. Probe 3 pins the subdirectory
      # case, which is the normal one for an agent working inside a repo.
      #
      # A per-repo probe that drives the actual verbs is strictly better and
      # cannot live here -- it has to know which verb writes and which needs a
      # network. INTERFACE.md shows how to add one via `extraChecks`.
      anchorCheck =
        pkgs:
        pkgs.runCommand "anchor-check" { } ''
          set -euo pipefail

          # The two preambles under test, verbatim, in a file the probes source.
          # A quoted heredoc, so every $ below is the bash the wrappers see.
          cat > preamble.sh <<'CANONICAL_PREAMBLE_EOF'
          ${rootPreamble}
          ${guardPreamble}
          CANONICAL_PREAMBLE_EOF

          mkdir decoy
          printf '{\n  description = "a different repo";\n  outputs = _: { };\n}\n' > decoy/flake.nix
          printf 'do not touch me\n' > decoy/victim.txt
          cp -r decoy decoy.orig

          # ---- probe 1: a foreign tree must not be adopted ----
          if ! ( cd decoy && . ../preamble.sh && [ "$REPO_ROOT" = "$SRC_ROOT" ] ); then
            echo "anchor adopted a directory that is not this repo" >&2
            exit 1
          fi
          # In a subshell: need_writable_checkout ends in `exit`, which would
          # otherwise take this whole build down instead of failing a condition.
          if ( cd decoy && . ../preamble.sh && need_writable_checkout ) > guard.log 2>&1; then
            echo "need_writable_checkout accepted a tree that is not this repo" >&2
            exit 1
          fi
          if ! diff -r decoy decoy.orig; then
            echo "the probes modified the foreign tree" >&2
            exit 1
          fi

          # ---- probe 2: a byte-identical checkout must be adopted ----
          cp -r ${lib.escapeShellArg "${self}"} checkout
          chmod -R u+w checkout
          if ! ( cd checkout && . ../preamble.sh &&
                 [ "$REPO_ROOT" = "$(pwd -P)" ] && need_writable_checkout ); then
            echo "anchor refused a byte-identical checkout of this repo" >&2
            exit 1
          fi

          # ---- probe 3: from a subdirectory, still the checkout root ----
          mkdir -p checkout/probe3/deeper
          if ! ( cd checkout/probe3/deeper && . ../../../preamble.sh &&
                 [ "$REPO_ROOT" = "$(cd -P ../.. && pwd)" ] ); then
            echo "anchor did not walk up to the checkout root from a subdirectory" >&2
            exit 1
          fi

          touch "$out"
        '';
    in
    {
      # `nix flake show` -- the discovery entrypoint, and deliberately the whole
      # machine-facing contract: every app carries a meta.description, which
      # `nix flake show` prints inline and `nix flake show --json` exposes at
      # .apps.<system>.<name>.description. Pure evaluation, so an agent gets the
      # entire command map in one cheap call without reading a README.
      #
      # Do NOT invent a top-level output for this (`agentManifest`, `probeThing`
      # ...). Nix answers with `warning: unknown flake output '<name>'` on every
      # single `nix flake check`, forever.
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

          # Natively-compiled extension modules are routinely built at -O0,
          # where glibc's _FORTIFY_SOURCE stops being a warning and becomes a
          # hard error.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            # $REPO_ROOT and $SRC_ROOT are exported here as a convenience for
            # the human at the prompt. Every wrapper re-resolves them from
            # scratch and none of them reads these, on purpose: a stale value
            # exported by one repo's shell must never steer another repo's verb.
            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No environment
            # bootstrapping, no dependency installation, no `read`, no
            # `exec $SHELL`. Bootstrapping in the hook makes a cold
            # `nix develop -c <anything>` start downloading before it runs
            # anything, on EVERY invocation -- the exact failure an unattended
            # agent cannot diagnose. That is what a `setup` verb is for.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "${repoName} dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction, and the only gate this
      # style has. `toolchain` realises the whole toolchain closure (so a typo'd
      # or currently-broken attr fails here, not halfway through a task) and
      # builds every wrapper, which runs shellcheck over every command text.
      # `anchoring` is the regression test described above.
      #
      # Repo-specific checks go in `extraChecks`, never here. They may not
      # shadow either canonical name: silently replacing `anchoring` with
      # something weaker is the exact failure this whole file exists to make
      # impossible, so a collision is an eval error with both names in it.
      #
      # NEVER add a check that always passes. An agent reads "all checks
      # passed!" as a signal, and a fake check makes `nix flake check` a liar.
      checks = forAllSystems (
        pkgs:
        let
          canonical = {
            toolchain =
              pkgs.runCommand "toolchain-check"
                {
                  nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];
                }
                ''
                  set -euo pipefail
                  dev-help > help.txt

                  # A while-read over a heredoc rather than `for x in <list>`,
                  # which is a bash syntax error when the list is empty -- and a
                  # repo with no verbs yet is a legitimate state.
                  while IFS= read -r verb; do
                    [ -n "$verb" ] || continue
                    command -v "dev-$verb" > /dev/null || {
                      echo "dev-$verb is not on PATH" >&2
                      exit 1
                    }
                    grep -q -- "dev-$verb" help.txt || {
                      echo "dev-$verb is missing from the dev-help map" >&2
                      exit 1
                    }
                  done <<'CANONICAL_VERBS_EOF'
                  ${lib.concatStringsSep "\n" (lib.attrNames (commands pkgs))}
                  CANONICAL_VERBS_EOF

                  touch "$out"
                '';
            anchoring = anchorCheck pkgs;
          };
          extra = extraChecks pkgs;
          clash = lib.intersectLists (lib.attrNames canonical) (lib.attrNames extra);
        in
        if clash != [ ] then
          throw "extraChecks must not redefine canonical checks: ${lib.concatStringsSep ", " clash}"
        else
          canonical // extra
      );

      # `nix fmt` -- formats the *Nix* in this repo; project code gets a `fmt`
      # verb. nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because
      # bare nixfmt tries to parse every path handed to it and fails on non-Nix
      # files. This file ships already formatted, so `nix fmt` is a no-op rather
      # than a diff across the fleet.
      #
      # This is the one verb here NOT anchored to $REPO_ROOT, and it cannot be:
      # `nix fmt` is nix's own verb, and nix -- not this flake -- decides which
      # paths the formatter receives, passing the cwd when the user names none.
      # A wrapper that overrode them would break `nix fmt path/to/one/file.nix`,
      # and it cannot tell that "." apart from the default. So `nix fmt` formats
      # where you stand, by design; the `fmt` verb is the anchored one.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
# >>>>> END CANONICAL MACHINERY v1 <<<<<
