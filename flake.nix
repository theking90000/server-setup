{
  description = "Server-Setup Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
    colmena.url = "github:zhaofengli/colmena";
  };

  outputs =
    {
      self,
      nixpkgs,
      colmena,
    }:
    {
      nixosModules.default = {
        imports = [
          colmena.nixosModules.deploymentOptions
          ./nixos/modules/default.nix
        ];
      };

      # On exporte tes fonctions utilitaires (ops.nix, services.nix)
      lib = import ./nixos/lib;

      # On package ton script d'infection pour pouvoir le lancer n'importe où
      # Support multi-architecture (Linux & macOS)
      packages =
        nixpkgs.lib.genAttrs
          [
            "x86_64-linux"
            "aarch64-linux"
            "x86_64-darwin"
            "aarch64-darwin"
          ]
          (
            system:
            let
              pkgs = nixpkgs.legacyPackages.${system};
              scripts = import ./scripts { inherit pkgs; };
            in
            scripts
            // {
              default = scripts.infect;
            }
          );
    };
}
