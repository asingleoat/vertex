{
  description = "vertex — persistent geometry visualization viewer with a hot-recompile loop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # sokol-shdc is distributed as a prebuilt binary (no nix-ld here), so
      # patchelf it into a proper derivation. Pinned to the sokol-tools-bin
      # commit that the sokol-zig dependency in build.zig.zon references.
      sokolShdc = pkgs: pkgs.stdenv.mkDerivation {
        pname = "sokol-shdc";
        version = "87a6914";
        src = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/floooh/sokol-tools-bin/87a6914bb5eab83f13b12db6dfd4c1333494d076/bin/linux/sokol-shdc";
          hash = "sha256-dzBip6oS3vprGiCh3SO2x0qGijyHLdXP+fawnnrnNXE=";
        };
        dontUnpack = true;
        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        buildInputs = [ pkgs.stdenv.cc.cc.lib ];
        installPhase = ''
          install -Dm755 $src $out/bin/sokol-shdc
        '';
      };
    in
    {
      packages = forAll (pkgs: { sokol-shdc = sokolShdc pkgs; });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            zig
            zls
            pkg-config
            watchexec   # fallback for `zig build --watch`
            gdb
            (sokolShdc pkgs)   # `zig build shaders`
          ];

          # System libraries sokol_app/sokol_gfx/sokol_audio link on Linux (GL + X11 backend).
          # mkShell exports them via NIX_CFLAGS_COMPILE / NIX_LDFLAGS, which zig's
          # native-paths detection reads, so `linkSystemLibrary` resolves without
          # any hardcoded paths.
          buildInputs = with pkgs; [
            # glibc headers are normally injected by the cc wrapper, which zig
            # and the external translate-c (Aro) don't go through; listing the
            # dev output here puts them on NIX_CFLAGS_COMPILE like any other lib.
            glibc.dev
            libglvnd
            libx11
            libxi
            libxcursor
            alsa-lib
          ];

          # Zig's global cache is per-user; keep the project cache local so a
          # `git clean` resets everything.
          shellHook = ''
            export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache"
          '';
        };
      });
    };
}
