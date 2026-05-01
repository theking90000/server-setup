{
  description = "Déploiement de l'infrastructure privée";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin";
    infra.url = "github:theking90000/server-setup";
    colmena.url = "github:zhaofengli/colmena";
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-darwin,
      infra,
      colmena,
      ...
    }:
    let
      lib = nixpkgs.lib;

      supportedSystems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);

      nodesData = import ./inventory/nodes.nix;

      mkNode = name: node: {
        imports = [
          ./inventory/hardware/${name}/hardware.nix
          ./config
          infra.nixosModules.default
        ];
        infra.nodeName = name;

        deployment.keys."wg-key" = {
          keyFile = ./inventory/wireguard/${name}/private.key;
          destDir = "/var/lib/secrets";
          user = "root";
          group = "root";
          permissions = "0400";
          name = "wg-key";
        };

        infra.acme.certSyncerPrivateKey = builtins.readFile ./inventory/keys/syncer.key;
        infra.acme.certSyncerPublicKey = builtins.readFile ./inventory/keys/syncer.key.pub;

        infra.nodes = lib.mkMerge [
          nodesData.nodes
          (builtins.mapAttrs (nodeName: _: {
            wireguardPublicKey = (builtins.readFile ./inventory/wireguard/${nodeName}/public.key) + "\n";
            sshPublicKey = builtins.readFile ./inventory/keys/${nodeName}/key.pub;
          }) nodesData.nodes)
        ];

        system.stateVersion = "23.11";

        deployment = {
          targetHost = node.publicIp;
          targetUser = "root";
          tags = node.tags;
          buildOnTarget = true;
        };

        networking.hostName = name;
      };

    in
    {
      colmena = {
        meta = {
          nixpkgs = import nixpkgs { system = "x86_64-linux"; };
        };
      }
      // builtins.mapAttrs mkNode nodesData.nodes;

      nixosConfigurations.validate = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          infra.nixosModules.default
          colmena.nixosModules.validate
          { infra = import ./inventory/nodes.nix; }
        ];
      };

      devShells = forAllSystems (system: {
        default =
          let
            isMac = nixpkgs.lib.hasSuffix "-darwin" system;
            pkgs = if isMac then nixpkgs-darwin.legacyPackages.${system} else nixpkgs.legacyPackages.${system};
          in
          pkgs.mkShell {
            buildInputs = [
              pkgs.colmena
              pkgs.just
              pkgs.jq
              pkgs.wireguard-tools
              pkgs.openssh

              infra.packages.${system}.infect
              infra.packages.${system}.adopt-hardware
              infra.packages.${system}.export-ssh-key
              infra.packages.${system}.generate-key
              infra.packages.${system}.generate-mesh
              infra.packages.${system}.bootstrap-project
            ];

            shellHook = ''
              ${if isMac then "export TMPDIR=/private/tmp" else ""}
              echo "================================================="
              echo " Bienvenue dans l'environnement de déploiement!"
              echo "================================================="
              echo "Système détecté : ${system}"
              echo "Tape 'just' pour voir les commandes disponibles."
            '';
          };
      });
    };
}
