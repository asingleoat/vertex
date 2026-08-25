{
  description = "vertex — persistent geometry visualization viewer with a hot-recompile loop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Bleeding-edge Zig (master / 0.17-dev): the std.Io work lands there first,
    # and sokol-zig + dcimgui master track zig master.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # zls built from source against the same master line.
    zls = {
      url = "github:zigtools/zls";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zig-overlay, zls }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # zig master bug (lib/compiler/Maker/Step/Compile.zig): the maker appends
      # `--dynamic-linker <path>` where <path> is a slice into a by-value local
      # `query`'s DynamicLinker buffer, which is dead by the time the args are
      # used, so the path arrives empty. Dupe it into the arena. Remove once
      # fixed upstream.
      zigFor = pkgs: (zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}.master).overrideAttrs (old: {
        # The overlay defines a custom installPhase that never runs postInstall.
        installPhase = old.installPhase + ''
          substituteInPlace $out/lib/compiler/Maker/Step/Compile.zig \
            --replace-fail 'zig_args.appendAssumeCapacity(dynamic_linker_path);' \
                           'zig_args.appendAssumeCapacity(try arena.dupe(u8, dynamic_linker_path));'
        '';
      });
      # System libraries sokol_app/sokol_gfx/sokol_audio link on Linux (GL + X11).
      sokolLibs = pkgs: pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux (with pkgs; [ libglvnd libx11 libxi libxcursor alsa-lib xorgproto libxext libxfixes ]);
      zlsFor = pkgs: zls.packages.${pkgs.stdenv.hostPlatform.system}.default;

      # sokol-shdc is distributed as prebuilt binaries (no nix-ld here), so
      # wrap the one for this platform in a derivation. Pinned to the
      # sokol-tools-bin commit that the sokol-zig dependency references.
      # Linux binaries need patchelf; the macOS ones run as-is.
      shdcBinaries = {
        x86_64-linux = { dir = "linux"; hash = "sha256-dzBip6oS3vprGiCh3SO2x0qGijyHLdXP+fawnnrnNXE="; };
        aarch64-darwin = { dir = "osx_arm64"; hash = "sha256-UihnNY/mIM23lwgOx24mDLAbuHI1xilJKUjpigVrS98="; };
        x86_64-darwin = { dir = "osx"; hash = "sha256-9Y45e5GAUs46zXx8s/LT0eMdAfHzKH3meZWbylDesvI="; };
      };
      sokolShdc = pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          bin = shdcBinaries.${system} or (throw "no prebuilt sokol-shdc for ${system}");
        in
        pkgs.stdenv.mkDerivation {
          pname = "sokol-shdc";
          version = "87a6914";
          src = pkgs.fetchurl {
            url = "https://raw.githubusercontent.com/floooh/sokol-tools-bin/87a6914bb5eab83f13b12db6dfd4c1333494d076/bin/${bin.dir}/sokol-shdc";
            hash = bin.hash;
          };
          dontUnpack = true;
          nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];
          buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.stdenv.cc.cc.lib ];
          installPhase = "install -Dm755 $src $out/bin/sokol-shdc";
        };
    in
    {
      packages = forAll (pkgs: { sokol-shdc = sokolShdc pkgs; });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            (zigFor pkgs)
            (zlsFor pkgs)
            pkg-config
            watchexec   # fallback for `zig build --watch`
            (sokolShdc pkgs)   # `zig build shaders`
          ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux (with pkgs; [
            xvfb-run    # scripts/smoke.sh (headless GL via llvmpipe)
            gdb
          ]);

          # glibc headers are normally injected by the cc wrapper, which the
          # external translate-c (Aro, used by dcimgui at configure time) does
          # not go through; listing the dev output puts them on
          # NIX_CFLAGS_COMPILE for host-native compilations.
          # Linux only: on macOS zig links the Cocoa/Metal frameworks from the
          # SDK itself (see HANDOFF-macos.md).
          buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux ([ pkgs.glibc.dev ] ++ sokolLibs pkgs);

          # Zig's global cache is per-user; keep the project cache local so a
          # `git clean` resets everything.
          # The glibc pin below applies to Linux only. The nixpkgs Darwin cc
          # wrapper also ships nix-support/dynamic-linker, holding
          # /usr/lib/dyld, so testing for that file is not sufficient; the guard
          # is on the platform instead.
          shellHook = ''
            export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache"
          '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
            # In zig 0.17.0-dev.1857, setting either NIX_CFLAGS_COMPILE or
            # NIX_LDFLAGS causes zig to skip its Darwin SDK detection, which
            # runs `xcrun --sdk macosx --show-sdk-path`. No framework search
            # path is then added, and every `-framework` in the sokol_app and
            # sokol_gfx link fails with `searched paths: none`. Neither
            # variable is needed here, because zig takes libSystem, the Cocoa,
            # Metal and OpenGL frameworks and the C headers from the SDK, and
            # ships its own libc++. Unsetting them restores detection, as on a
            # Mac without nix. DEVELOPER_DIR and SDKROOT, set by the apple-sdk
            # setup hook, point xcrun at the pinned nixpkgs SDK, so detection
            # remains reproducible.
            unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
          '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
            # zig's compiler detects the native dynamic linker by probing
            # /usr/bin/env, i.e. the *system* glibc, while this shell links
            # against nixpkgs' glibc. Mixed ld.so/libc versions fail to load,
            # so build.zig pins the target to this shell's glibc (dynamic
            # linker + version) and takes the libraries sokol links as explicit
            # search prefixes (ZIG_SEARCH_PREFIXES, lib and dev outputs).
            if [ -f "$NIX_CC/nix-support/dynamic-linker" ]; then
              export ZIG_DYNAMIC_LINKER="$(cat "$NIX_CC/nix-support/dynamic-linker")"
              export ZIG_GLIBC_VERSION="$(basename "$(cat "$NIX_CC/nix-support/orig-libc")" | sed -E 's/.*-glibc-([0-9]+\.[0-9]+).*/\1/')"
              export ZIG_SEARCH_PREFIXES="${pkgs.lib.concatStringsSep ":" (map (p: "${pkgs.lib.getLib p}") (sokolLibs pkgs) ++ map (p: "${pkgs.lib.getDev p}") (sokolLibs pkgs))}"
            fi
          '';
        };
      });
    };
}
