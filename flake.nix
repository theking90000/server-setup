{
  description = "Server-Setup Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin";
    colmena.url = "github:zhaofengli/colmena";
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-darwin,
      ...
    }:
    {
      nixosModules.default = {
        imports = [
          ./nixos/modules
        ];
      };

      # On exporte tes fonctions utilitaires (ops.nix, services.nix)
      # lib = import ./nixos/lib;

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
              isMac = nixpkgs.lib.hasSuffix "-darwin" system;
              pkgs = if isMac then nixpkgs-darwin.legacyPackages.${system} else nixpkgs.legacyPackages.${system};
              scripts = import ./scripts { inherit pkgs; };
            in
            scripts
            // {
              default = scripts.infect;
            }
          );
    };
}
