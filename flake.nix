{
  description = "Zig coreutils with modern UX";

  nixConfig = {
    extra-substituters = [ "https://vibeutils.cachix.org" ];
    extra-trusted-public-keys = [
      "vibeutils.cachix.org-1:kZjdX4Bz2/VdgK9dCwE5G3C7ygrptzPTFQMH32Ng0WU="
    ];
  };

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
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "vibeutils";
          version = "0.7.2";

          src = ./.;

          nativeBuildInputs = [ zig ];

          dontConfigure = true;

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
          packages = [
            zig
            pkgs.actionlint
            pkgs.bash
            pkgs.coreutils
            pkgs.gnumake
            pkgs.mandoc
          ];
        };
      }
    );
}
