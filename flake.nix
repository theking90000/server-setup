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
              infra.grafana.grafanaSecret = "test";
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
                "web-server"
                "applications/docker-registry"
                "applications/filesave-server"
                "applications/gitea"
                "applications/jellyfin"
                "applications/ntfy"
                "applications/reposilite"
                "applications/sncb-insights"
                "applications/www"
                "acme-issuer"
              ];
            };
          }
          [
            {
              infra.acme = {
                email = "test@example.test";
                dnsProvider = "ovh";
                dnsCredentials = "OVH_APPLICATION_KEY=test";
                certSyncerPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest";
                domains = [
                  {
                    domain = "example.test";
                    services = [ "nginx" ];
                  }
                ];
              };
              infra.dockerRegistry.accounts = "test:test";
              infra.grafana.password = "test";
              infra.grafana.grafanaSecret = "test";
              infra.restic.repository = "local:/tmp/backup";
              infra.restic.password = "test";
              infra.sncb-insights.package = checkPkgs.writeShellScriptBin "sncb-insights" "exit 0";
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
      grafanaSsoNode =
        mkNode
          {
            test = baseNode // {
              tags = [
                "grafana"
                "kanidm"
              ];
            };
          }
          [
            {
              infra.grafana = {
                url = "https://grafana.example.test";
                passwordFile = "/run/secrets/grafana/password";
                grafanaSecretFile = "/run/secrets/grafana/secret";
              };
              infra.kanidm.url = "https://auth.example.test";
            }
          ];
      rcloneMount = lib.findFirst (
        mount: mount.where == "/mnt/test"
      ) null fileSecretsNode.config.systemd.mounts;
      rcloneConfigService = fileSecretsNode.config.systemd.services.rclone-config-test;
      templateNode = mkNode {
        test = baseNode // {
          tags = [ ];
        };
      } [ ./template/config ];
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
        grafana-sso =
          assert builtins.hasAttr "grafana" grafanaSsoNode.config.infra.sso;
          assert
            builtins.attrNames grafanaSsoNode.config.infra.sso.grafana.groups == [
              "admins"
              "editors"
              "viewers"
            ];
          assert grafanaSsoNode.config.services.kanidm.provision.enable;
          assert !grafanaSsoNode.config.services.kanidm.provision.autoRemove;
          assert
            grafanaSsoNode.config.services.kanidm.provision.idmAdminPasswordFile
            == "/run/secrets/kanidm/idm-admin-password";
          assert !grafanaSsoNode.config.services.kanidm.provision.groups.grafana_admins.overwriteMembers;
          assert
            grafanaSsoNode.config.services.kanidm.provision.systems.oauth2.grafana.scopeMaps.grafana_viewers
            == [
              "openid"
              "profile"
              "email"
              "groups"
            ];
          assert
            grafanaSsoNode.config.services.kanidm.provision.systems.oauth2.grafana.claimMaps.grafana_role.valuesByGroup.grafana_admins
            == [
              "Admin"
            ];
          assert grafanaSsoNode.config.services.grafana.settings.auth.disable_login_form;
          assert !grafanaSsoNode.config.services.grafana.settings."auth.basic".enabled;
          assert grafanaSsoNode.config.services.grafana.settings."auth.generic_oauth".enabled;
          assert grafanaSsoNode.config.services.grafana.settings."auth.generic_oauth".auto_login;
          assert builtins.elem "oidc_client_secret:/run/secrets/sso/grafana-client-secret"
            grafanaSsoNode.config.systemd.services.grafana.serviceConfig.LoadCredential;
          mkEvalCheck "grafana-sso" grafanaSsoNode;
        rclone-config =
          assert rcloneMount != null;
          assert lib.hasInfix "config=/var/lib/rclone-sync/test/rclone.conf" rcloneMount.options;
          assert builtins.elem "rclone-config-test.service" rcloneMount.requires;
          assert lib.toList rcloneConfigService.serviceConfig.StateDirectory == [ "rclone-sync/test" ];
          assert rcloneConfigService.serviceConfig.StateDirectoryMode == "0700";
          assert rcloneConfigService.serviceConfig.UMask == "0077";
          assert !builtins.hasAttr "rclone-token-test" fileSecretsNode.config.systemd.services;
          mkEvalCheck "rclone-config" fileSecretsNode;
        ssh-port =
          assert minimalNode.config.services.openssh.ports == [ 2222 ];
          mkEvalCheck "ssh-port" minimalNode;
        template =
          assert builtins.isAttrs templateParsed;
          assert builtins.pathExists ./template/inventory/hardware/vps1/hardware.nix;
          mkEvalCheck "template" templateNode;
        template-config-boundary =
          checkPkgs.runCommand "template-config-boundary"
            {
              nativeBuildInputs = [ checkPkgs.ripgrep ];
            }
            ''
              if rg -n '(sops\.|sopsFile|deployment\.keys|/run/secrets|builtins\.readFile|dnsCredentials[[:space:]]*=|accounts[[:space:]]*=|password(File)?[[:space:]]*=|grafanaSecret(File)?[[:space:]]*=|repository(File)?[[:space:]]*=|env(File)?[[:space:]]*=|config(Content|File)[[:space:]]*=)' ${./template/config}; then
                echo 'template/config must contain only functional infra.* choices' >&2
                exit 1
              fi
              touch "$out"
            '';
        infect-parser = checkPkgs.runCommand "infect-parser" { nativeBuildInputs = [ checkPkgs.bash ]; } ''
          bash ${./scripts/test-infect.sh}
          touch "$out"
        '';
        script-syntax = checkPkgs.runCommand "script-syntax" { nativeBuildInputs = [ checkPkgs.bash ]; } ''
          for script in ${./scripts}/*.sh; do
            bash -n "$script"
          done
          touch "$out"
        '';
        script-packages = checkPkgs.symlinkJoin {
          name = "script-packages";
          paths = lib.attrValues (builtins.removeAttrs self.packages.x86_64-linux [ "default" ]);
        };
      };
    };
}
