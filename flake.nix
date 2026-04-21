{
  description = "Server-Setup Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
    colmena.url = "github:zhaofengli/colmena";
  };

  outputs =
    { self, nixpkgs, colmena }:
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
            in
            {
              infect = pkgs.writeShellApplication {
                name = "infect-server";
                runtimeInputs = [
                  pkgs.curl
                  pkgs.openssh
                ];
                text = builtins.readFile ./scripts/infect.sh;
              };
              default = pkgs.writeShellApplication {
                name = "infect-server";
                runtimeInputs = [
                  pkgs.curl
                  pkgs.openssh
                ];
                text = builtins.readFile ./scripts/infect.sh;
              };
            }
          );

      # (Optionnel) Tu peux aussi garder l'output Colmena direct ici TEMPORAIREMENT
      # si tu veux tester les flakes sans encore créer le 2ème dépôt privé
      # colmena = {
      #   meta = { nixpkgs = import nixpkgs { system = "x86_64-linux"; }; };
      # } // (
      #   let
      #     topo = import ./inventory/topology.nix;
      #     generateNode = name: data: import ./nixos/node.nix { inherit name data; };
      #   in
      #   builtins.mapAttrs generateNode topo.nodes
      # );
    };
}
