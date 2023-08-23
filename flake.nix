{
  description = "A flake to build Ogmios";
  inputs.haskellNix.url = "github:input-output-hk/haskell.nix";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.iohkNix.url = "github:input-output-hk/iohk-nix";
  inputs.CHaP = {
      url = "github:input-output-hk/cardano-haskell-packages";
      flake = false;
    };
  outputs = { self, nixpkgs, flake-utils, haskellNix, iohkNix, CHaP }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ] (system:
    let
      overlays = [ haskellNix.overlay
        (final: prev: {
          # This overlay adds our project to pkgs
          ogmios =
            final.haskell-nix.project' {
              # pass inputMap to haskell.nix
              inputMap = { "https://input-output-hk.github.io/cardano-haskell-packages" = CHaP; };
              src = final.haskell-nix.haskellLib.cleanSourceWith {
                name = "ogmios-src";
                src = ./.;
                subDir = "server";
                filter = path: type:
                  builtins.all (x: x) [
                    (baseNameOf path != "package.yaml")
                  ];
              };
              compiler-nix-name = "ghc928";
              # This is used by `nix develop .` to open a shell for use with
              # `cabal`, `hlint` and `haskell-language-server`
              shell.tools = {
                cabal = {};
                hlint = {};
                haskell-language-server = {};
              };
              # Non-Haskell shell tools go here
              shell.buildInputs = with pkgs; [
                nixpkgs-fmt
              ];
            };
        })
      ] ++ [ iohkNix.overlays.crypto ];
      pkgs = import nixpkgs { inherit system overlays; inherit (haskellNix) config; };
      flake = pkgs.ogmios.flake {
      };
    in flake // {
      # Built by `nix build .`
      packages.default = flake.packages."ogmios:exe:ogmios";
    });
}
