{
  description = "Déploiement de l'infrastructure privée";

  inputs = {
    nixpkgs.follows = "infra/nixpkgs";
    nixpkgs-darwin.follows = "infra/nixpkgs-darwin";
    infra.url = "github:theking90000/server-setup";
    colmena.url = "github:zhaofengli/colmena";

    # Pas de `inputs.nixpkgs.follows` ici : le cache binaire
    # nixos-raspberrypi.cachix.org n'a que les builds faits contre LEUR
    # nixpkgs lockée. Suivre la nôtre changerait les hashs → recompilation
    # du kernel sur les Pi.
    nixos-raspberrypi.url = "github:nixos-26.05/nixos-raspberrypi/main";
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-darwin,
      infra,
      colmena,
      nixos-raspberrypi,
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
        ]
        ++ lib.optionals (builtins.elem "raspberry-pi" node.tags) [
          nixos-raspberrypi.nixosModules.raspberry-pi-5.base
          # Substituter nixos-raspberrypi.cachix.org sur le noeud lui-même
          # (nécessaire avec buildOnTarget = true).
          nixos-raspberrypi.nixosModules.trusted-nix-caches
          # La nixpkgs des Pi (lock de nixos-raspberrypi) est plus ancienne
          # que celle de l'infra, or les modules infra référencent les options
          # kanidm récentes (services.kanidm.server/client). On substitue donc
          # le module kanidm par celui de la nixpkgs infra.
          { disabledModules = [ "services/security/kanidm.nix" ]; }
          "${nixpkgs}/nixos/modules/services/security/kanidm.nix"
        ];

        infra.nodeName = name;

        infra.sops.secretsDirectory = ./secrets;

        infra.nodes = lib.mkMerge [
          nodesData.nodes
          (builtins.mapAttrs (nodeName: _: {
            wireguardPublicKey = (builtins.readFile ./inventory/wireguard/${nodeName}/public.key) + "\n";
            sshPublicKey = builtins.readFile ./inventory/keys/${nodeName}/key.pub;
          }) nodesData.nodes)
        ];

        # Initial state version for machines created from this template. Never
        # advance it in an existing private repository.
        system.stateVersion = "26.05";

        deployment = {
          targetHost = node.publicIp;
          targetPort = node.sshPort or 22;
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
          # Le default obligatoire pour calmer l'évaluateur de Colmena
          nixpkgs = import nixpkgs { system = "x86_64-linux"; };

          # La magie noire pour le multi-architecture : on instancie dynamiquement
          # nixpkgs pour CHAQUE noeud, avec son overlay associé.
          nodeNixpkgs = builtins.mapAttrs (
            name: node:
            let
              isPi = builtins.elem "raspberry-pi" node.tags;
            in
            # Les Pi utilisent la nixpkgs lockée par nixos-raspberrypi pour
            # profiter de son cache binaire (kernel vendor pré-compilé).
            import (if isPi then nixos-raspberrypi.inputs.nixpkgs else nixpkgs) {
              system = if isPi then "aarch64-linux" else "x86_64-linux";
              overlays =
                lib.optionals isPi [
                  nixos-raspberrypi.overlays.bootloader
                  nixos-raspberrypi.overlays.vendor-kernel
                  nixos-raspberrypi.overlays.vendor-firmware
                  nixos-raspberrypi.overlays.kernel-and-firmware
                  nixos-raspberrypi.overlays.vendor-pkgs
                ];
            }
          ) nodesData.nodes;

          specialArgs = { inherit nixos-raspberrypi infra; };
        };
      }
      // builtins.mapAttrs mkNode nodesData.nodes;

      devShells = forAllSystems (system: {
        default =
          let
            isMac = nixpkgs.lib.hasSuffix "-darwin" system;
            pkgs = if isMac then nixpkgs-darwin.legacyPackages.${system} else nixpkgs.legacyPackages.${system};
          in
          pkgs.mkShell {
            buildInputs = [
              pkgs.colmena
              pkgs.jq
              pkgs.wireguard-tools
              pkgs.openssh
              pkgs.ripgrep
              pkgs.sops
              pkgs.ssh-to-age

              infra.packages.${system}.infect
              infra.packages.${system}.adopt-hardware
              infra.packages.${system}.export-ssh-key
              infra.packages.${system}.generate-mesh
              infra.packages.${system}.update-sops-keys
              infra.packages.${system}.init-project
              infra.packages.${system}.check-project
              infra.packages.${system}.deploy-project
              infra.packages.${system}.bootstrap-project
            ];

            shellHook = ''
              ${if isMac then "export TMPDIR=/private/tmp" else ""}
              echo "================================================="
              echo " Bienvenue dans l'environnement de déploiement!"
              echo "================================================="
              echo "Système détecté : ${system}"
              echo "Run 'init-project', 'check-project' or 'deploy-project'."
            '';
          };
      });
    };
}
