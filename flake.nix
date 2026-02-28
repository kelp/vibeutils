{
  description = "Zig coreutils with modern UX";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachSystem [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        zig = zig-overlay.packages.${system}."0.15.2";
      in {
        packages.default = pkgs.stdenvNoCC.mkDerivation {
          pname = "vibeutils";
          version = "0.5.0";

          src = ./.;

          nativeBuildInputs = [ zig ];

          dontConfigure = true;
          dontFixup = true;

          buildPhase = ''
            export XDG_CACHE_HOME="$TMPDIR/xdg-cache"
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            mkdir -p "$XDG_CACHE_HOME" "$ZIG_GLOBAL_CACHE_DIR"
            zig build -Doptimize=ReleaseSafe --prefix $out
          '';

          installPhase = ''
            mkdir -p $out/share/man/man1
            cp -r man/man1/* $out/share/man/man1/
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [ zig ];
        };
      }
    );
}
