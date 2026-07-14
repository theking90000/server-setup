{
  description = "Déploiement de l'infrastructure privée";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin";
    infra.url = "github:theking90000/server-setup";
    colmena.url = "github:zhaofengli/colmena";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-darwin,
      infra,
      colmena,
      sops-nix,
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
          ./secrets
          infra.nixosModules.default
          sops-nix.nixosModules.sops
        ]
        ++ lib.optionals (builtins.elem "raspberry-pi" node.tags) [
          nixos-raspberrypi.nixosModules.raspberry-pi-5.base
          nixos-raspberrypi.nixosModules.raspberry-pi-5.page-size-16k
        ];

        infra.nodeName = name;

        infra.nodes = lib.mkMerge [
          nodesData.nodes
          (builtins.mapAttrs (nodeName: _: {
            wireguardPublicKey = (builtins.readFile ./inventory/wireguard/${nodeName}/public.key) + "\n";
            sshPublicKey = builtins.readFile ./inventory/keys/${nodeName}/key.pub;
          }) nodesData.nodes)
        ];

        system.stateVersion = if builtins.elem "raspberry-pi" node.tags then "25.05" else "23.11";

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
            import nixpkgs {
              system = if isPi then "aarch64-linux" else "x86_64-linux";
              overlays =
                lib.optionals isPi [
                  nixos-raspberrypi.overlays.pkgs
                  nixos-raspberrypi.overlays.bootloader
                  nixos-raspberrypi.overlays.vendor-kernel
                  nixos-raspberrypi.overlays.vendor-firmware
                  nixos-raspberrypi.overlays.kernel-and-firmware
                  nixos-raspberrypi.overlays.vendor-pkgs
                ]
                ++ lib.optionals isPi [
                  # Fix: le ffmpeg_7-full du RPi overlay (ffmpeg_7-rpi.nix)
                  # n'accepte pas les arguments `version`/`source` dont a besoin
                  # jellyfin-ffmpeg via .override {}. On remplace jellyfin-ffmpeg
                  # par la version vanilla de nixpkgs (sans accélération hardware
                  # RPi, mais fonctionnelle).
                  (final: prev: {
                    jellyfin-ffmpeg = nixpkgs.legacyPackages.aarch64-linux.jellyfin-ffmpeg;
                  })
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
              pkgs.just
              pkgs.jq
              pkgs.wireguard-tools
              pkgs.openssh
              pkgs.ripgrep
              pkgs.sops
              pkgs.ssh-to-age

              infra.packages.${system}.infect
              infra.packages.${system}.adopt-hardware
              infra.packages.${system}.export-ssh-key
              infra.packages.${system}.generate-key
              infra.packages.${system}.generate-mesh
              infra.packages.${system}.bootstrap-project
            ];

            shellHook = ''
              ${if isMac then "export TMPDIR=/private/tmp" else ""}
              export SOPS_AGE_KEY_CMD="ssh-to-age -private-key -i $HOME/.ssh/id_ed25519"
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
