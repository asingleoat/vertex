{
  description = "vertex — persistent geometry visualization viewer with a hot-recompile loop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            zig
            zls
            pkg-config
            watchexec   # fallback for `zig build --watch`
            gdb
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
