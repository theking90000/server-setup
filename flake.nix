{
  description = "Server-Setup Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin";
    colmena.url = "github:zhaofengli/colmena";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-darwin,
      colmena,
      ...
    }:
    let
      lib = nixpkgs.lib;
      checkPkgs = nixpkgs.legacyPackages.x86_64-linux;
      mkNode =
        nodes: extraModules:
        lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            name = "test";
            inherit nodes;
          };
          modules = [
            colmena.nixosModules.deploymentOptions
            self.nixosModules.default
            {
              boot.loader.grub.devices = [ "nodev" ];
              fileSystems."/" = {
                device = "none";
                fsType = "tmpfs";
              };
              infra.nodeName = "test";
              infra.nodes = nodes;
              system.stateVersion = "25.11";
            }
          ]
          ++ extraModules;
        };
      baseNode = {
        publicIp = "192.0.2.1";
        vpnIp = "10.100.0.1";
        sshPort = 2222;
      };
      mkEvalCheck =
        name: node:
        let
          drvPath = builtins.unsafeDiscardStringContext node.config.system.build.toplevel.drvPath;
        in
        checkPkgs.runCommand name { } ''
          echo ${lib.escapeShellArg drvPath} > "$out"
        '';
      minimalNode = mkNode {
        test = baseNode // {
          tags = [ ];
        };
      } [ ];
      optionalUrlsNode =
        mkNode
          {
            test = baseNode // {
              tags = [
                "grafana"
                "applications/gitea"
                "applications/ntfy"
              ];
            };
          }
          [
            {
              infra.grafana.password = "test";
              infra.grafana.grafana_secret = "test";
            }
          ];
      stableServicesNode =
        mkNode
          {
            test = baseNode // {
              tags = [
                "backup"
                "grafana"
                "node-metrics"
                "prometheus"
                "applications/docker-registry"
                "applications/gitea"
                "applications/ntfy"
                "applications/reposilite"
              ];
            };
          }
          [
            {
              infra.dockerRegistry.accounts = "test:test";
              infra.grafana.password = "test";
              infra.grafana.grafana_secret = "test";
              infra.restic.repository = "local:/tmp/backup";
              infra.restic.password = "test";
            }
          ];
      fileSecretsNode =
        mkNode
          {
            test = baseNode // {
              tags = [
                "backup"
                "grafana"
                "applications/docker-registry"
              ];
            };
          }
          [
            {
              infra.dockerRegistry.accountsFile = "/run/secrets/docker-registry/accounts";
              infra.grafana.passwordFile = "/run/secrets/grafana/password";
              infra.grafana.grafanaSecretFile = "/run/secrets/grafana/secret";
              infra.restic.repositoryFile = "/run/secrets/restic/repository";
              infra.restic.passwordFile = "/run/secrets/restic/password";
              infra.restic.envFile = "/run/secrets/restic/env";
              infra.wireguard.privateKeyFile = "/run/secrets/wireguard/private";
              infra.rcloneSync.mounts.test = {
                mountPoint = "/mnt/test";
                targetNodes = [ "test" ];
                remoteName = "test";
                configFile = "/run/secrets/rclone/test";
              };
            }
          ];
      templateParsed = import ./template/flake.nix;
    in
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

      checks.x86_64-linux = {
        minimal-module = mkEvalCheck "minimal-module" minimalNode;
        optional-urls = mkEvalCheck "optional-urls" optionalUrlsNode;
        stable-services = mkEvalCheck "stable-services" stableServicesNode;
        file-secrets = mkEvalCheck "file-secrets" fileSecretsNode;
        ssh-port =
          assert minimalNode.config.services.openssh.ports == [ 2222 ];
          mkEvalCheck "ssh-port" minimalNode;
        template =
          assert builtins.isAttrs templateParsed;
          assert builtins.pathExists ./template/inventory/hardware/vps1/hardware.nix;
          checkPkgs.runCommand "template" { } ''touch "$out"'';
        infect-parser = checkPkgs.runCommand "infect-parser" { nativeBuildInputs = [ checkPkgs.bash ]; } ''
          bash ${./scripts/test-infect.sh}
          touch "$out"
        '';
      };
    };
}
