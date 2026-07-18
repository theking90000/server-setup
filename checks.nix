{
  self,
  nixpkgs,
  colmena,
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
          infra.sops.secretsDirectory = ./tests/sops;
          sops.validateSopsFiles = false;
          system.stateVersion = "25.11";
        }
      ]
      ++ extraModules;
    };
  baseNode = {
    publicIp = "192.0.2.1";
    vpnIp = "10.100.0.1";
    sshPort = 2222;
    wireguardPublicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };
  mkEvalCheck =
    name: node:
    let
      drvPath = builtins.unsafeDiscardStringContext node.config.system.build.toplevel.drvPath;
    in
    checkPkgs.runCommand name { } ''
      echo ${lib.escapeShellArg drvPath} > "$out"
    '';
  minimalNode =
    mkNode
      {
        test = baseNode // {
          tags = [ ];
        };
      }
      [
        { infra.wireguard.privateKeyFile = "/tmp/wireguard-private-key"; }
      ];
  inactiveServiceValue = throw "configuration of an inactive service was evaluated";
  inactiveServicesNode =
    mkNode
      {
        test = baseNode // {
          tags = [ "web-server" ];
        };
      }
      [
        {
          infra.acme.email = inactiveServiceValue;
          infra.dockerRegistry = {
            url = inactiveServiceValue;
            accounts = inactiveServiceValue;
          };
          infra.filesave.url = inactiveServiceValue;
          infra.gitea = {
            url = inactiveServiceValue;
            registrationEnabled = inactiveServiceValue;
          };
          infra.grafana = {
            url = inactiveServiceValue;
            user = inactiveServiceValue;
          };
          infra.jellyfin.url = inactiveServiceValue;
          infra.kanidm.url = inactiveServiceValue;
          infra.ntfy = {
            url = inactiveServiceValue;
            upstream-base-url = inactiveServiceValue;
          };
          infra.qbittorrent = {
            url = inactiveServiceValue;
            torrentingPort = inactiveServiceValue;
          };
          infra.reposilite.url = inactiveServiceValue;
          infra.rust-storage-streamer.s3Url = inactiveServiceValue;
          infra.synapse = {
            url = inactiveServiceValue;
            serverName = inactiveServiceValue;
          };
          infra.restic = {
            repository = inactiveServiceValue;
            password = inactiveServiceValue;
            env = inactiveServiceValue;
          };
          infra.sncb-insights = {
            package = inactiveServiceValue;
            url = inactiveServiceValue;
          };
          infra.www.url = inactiveServiceValue;
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
            "applications/qbittorrent"
            "applications/reposilite"
            "applications/sncb-insights"
            "applications/synapse"
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
          infra.synapse = {
            url = "https://matrix.example.test";
            serverName = "example.test";
          };
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
  giteaSsoNode =
    mkNode
      {
        test = baseNode // {
          tags = [
            "applications/gitea"
            "kanidm"
          ];
        };
      }
      [
        {
          infra.gitea.url = "https://git.example.test";
          infra.kanidm.url = "https://auth.example.test";
        }
      ];
  synapseSsoNode =
    mkNode
      {
        test = baseNode // {
          tags = [
            "applications/synapse"
            "backup"
            "kanidm"
            "prometheus"
            "web-server"
          ];
        };
      }
      [
        {
          infra.kanidm.url = "https://auth.example.test";
          infra.restic = {
            repository = "local:/tmp/backup";
            password = "test";
          };
          infra.synapse = {
            url = "https://matrix.example.test";
            serverName = "example.test";
          };
        }
      ];
  rustStorageStreamerNode =
    mkNode
      {
        test = baseNode // {
          tags = [
            "applications/rust-storage-streamer"
            "backup"
            "web-server"
          ];
        };
      }
      [
        {
          infra.restic = {
            repository = "local:/tmp/backup";
            password = "test";
          };
          infra.rust-storage-streamer.s3Url = "https://storage.example.test";
        }
      ];
  qbittorrentNode =
    mkNode
      {
        test = baseNode // {
          tags = [
            "applications/qbittorrent"
            "backup"
            "web-server"
          ];
        };
      }
      [
        {
          infra.restic = {
            repository = "local:/tmp/backup";
            password = "test";
          };
          infra.qbittorrent = {
            url = "https://qbt.example.test";
            torrentingPort = 62000;
          };
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
  wireguardSopsNode = mkNode {
    test = baseNode // {
      tags = [ ];
    };
  } [ ];
  acmeIssuerSopsNode =
    mkNode
      {
        test = baseNode // {
          tags = [ "acme-issuer" ];
        };
      }
      [
        {
          infra.acme = {
            email = "test@example.test";
            dnsProvider = "ovh";
            certSyncerPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest";
            domains = [ { domain = "example.test"; } ];
          };
        }
      ];
  acmeConsumerSopsNode =
    mkNode
      {
        test = baseNode // {
          tags = [ ];
        };
        issuer = baseNode // {
          publicIp = "192.0.2.2";
          vpnIp = "10.100.0.2";
          tags = [ "acme-issuer" ];
        };
      }
      [
        { infra.acme.domains = [ { domain = "example.test"; } ]; }
      ];
  grafanaSopsNode =
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
          infra.grafana.url = "https://grafana.example.test";
          infra.kanidm.url = "https://auth.example.test";
        }
      ];
  registrySopsNode = mkNode {
    test = baseNode // {
      tags = [ "applications/docker-registry" ];
    };
  } [ ];
  resticSopsNode = mkNode {
    test = baseNode // {
      tags = [ "backup" ];
    };
  } [ ];
  rcloneSopsNode =
    mkNode
      {
        test = baseNode // {
          tags = [ ];
        };
      }
      [
        {
          infra.rcloneSync.mounts.test = {
            mountPoint = "/mnt/test";
            targetNodes = [ "test" ];
            remoteName = "test";
          };
        }
      ];
  assertSecret =
    node: name: file: key:
    let
      secret = node.config.sops.secrets.${name};
    in
    assert secret.path == "/run/secrets/${name}";
    assert secret.sopsFile == file;
    assert secret.key == key;
    true;
  templateParsed = import ./template/flake.nix;
in
{
  minimal-module =
    assert minimalNode.config.sops.secrets == { };
    assert minimalNode.config.services.openssh.ports == [ 2222 ];
    mkEvalCheck "minimal-module" minimalNode;
  inactive-service-config = mkEvalCheck "inactive-service-config" inactiveServicesNode;
  stable-services = mkEvalCheck "stable-services" stableServicesNode;
  file-secrets =
    assert fileSecretsNode.config.sops.secrets == { };
    assert rcloneMount != null;
    assert lib.hasInfix "config=/var/lib/rclone-sync/test/rclone.conf" rcloneMount.options;
    assert builtins.elem "rclone-config-test.service" rcloneMount.requires;
    assert lib.toList rcloneConfigService.serviceConfig.StateDirectory == [ "rclone-sync/test" ];
    assert rcloneConfigService.serviceConfig.StateDirectoryMode == "0700";
    assert rcloneConfigService.serviceConfig.UMask == "0077";
    assert !builtins.hasAttr "rclone-token-test" fileSecretsNode.config.systemd.services;
    mkEvalCheck "file-secrets" fileSecretsNode;
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
    assert
      grafanaSsoNode.config.services.grafana.settings."auth.generic_oauth".auth_style == "InParams";
    assert builtins.elem "oidc_client_secret:/run/secrets/sso/grafana-client-secret"
      grafanaSsoNode.config.systemd.services.grafana.serviceConfig.LoadCredential;
    mkEvalCheck "grafana-sso" grafanaSsoNode;
  gitea-sso =
    assert builtins.attrNames giteaSsoNode.config.infra.sso.gitea.groups == [ "users" ];
    assert !giteaSsoNode.config.infra.sso.gitea.pkce;
    assert
      giteaSsoNode.config.infra.sso.gitea.redirectUris == [
        "https://git.example.test/user/oauth2/kanidm/callback"
      ];
    assert giteaSsoNode.config.services.gitea.settings.oauth2_client.ACCOUNT_LINKING == "login";
    assert giteaSsoNode.config.services.gitea.settings.oauth2_client.USERNAME == "preferred_username";
    assert
      giteaSsoNode.config.services.kanidm.provision.systems.oauth2.gitea.allowInsecureClientDisablePkce;
    assert builtins.elem "oidc_client_secret:/run/secrets/sso/gitea-client-secret"
      giteaSsoNode.config.systemd.services.gitea.serviceConfig.LoadCredential;
    assert builtins.elem "kanidm.service" giteaSsoNode.config.systemd.services.gitea.after;
    assert lib.hasInfix "gsub(/^[[:space:]]+" giteaSsoNode.config.systemd.services.gitea.preStart;
    assert lib.hasInfix "admin auth add-oauth" giteaSsoNode.config.systemd.services.gitea.preStart;
    assert lib.hasInfix "admin auth update-oauth" giteaSsoNode.config.systemd.services.gitea.preStart;
    assert assertSecret giteaSsoNode "sso/gitea-client-secret" ./tests/sops/gitea.json
      "oidc_client_secret";
    assert giteaSsoNode.config.sops.secrets."sso/gitea-client-secret".owner == "kanidm";
    assert giteaSsoNode.config.sops.secrets."sso/gitea-client-secret".mode == "0400";
    mkEvalCheck "gitea-sso" giteaSsoNode;
  synapse =
    let
      oidc = builtins.head synapseSsoNode.config.services.matrix-synapse.settings.oidc_providers;
      oauth2 = synapseSsoNode.config.services.kanidm.provision.systems.oauth2.synapse;
      backup = synapseSsoNode.config.services.restic.backups."host-backup";
      serverDelegation =
        synapseSsoNode.config.services.nginx.virtualHosts."example.test".locations."= /.well-known/matrix/server";
    in
    assert builtins.attrNames synapseSsoNode.config.infra.sso.synapse.groups == [ "users" ];
    assert synapseSsoNode.config.infra.sso.synapse.pkce;
    assert
      synapseSsoNode.config.infra.sso.synapse.redirectUris == [
        "https://matrix.example.test/_synapse/client/oidc/callback"
      ];
    assert !oauth2.allowInsecureClientDisablePkce;
    assert oauth2.basicSecretFile == "/run/secrets/sso/synapse-client-secret";
    assert oidc.issuer == "https://auth.example.test/oauth2/openid/synapse/";
    assert oidc.client_secret_path == "/run/credentials/matrix-synapse.service/oidc_client_secret";
    assert oidc.pkce_method == "always";
    assert oidc.allow_existing_users;
    assert !synapseSsoNode.config.services.matrix-synapse.settings.password_config.localdb_enabled;
    assert
      synapseSsoNode.config.services.matrix-synapse.settings.database.args.database == "matrix-synapse";
    assert synapseSsoNode.config.services.matrix-synapse.settings.serve_server_wellknown == false;
    assert synapseSsoNode.config.services.postgresql.enable;
    assert lib.hasInfix "--locale=C" synapseSsoNode.config.systemd.services.postgresql-setup.script;
    assert builtins.elem "oidc_client_secret:/run/secrets/sso/synapse-client-secret"
      synapseSsoNode.config.systemd.services.matrix-synapse.serviceConfig.LoadCredential;
    assert synapseSsoNode.config.infra.ingress.synapse.backend == [ "10.100.0.1:8008" ];
    assert synapseSsoNode.config.infra.ingress.synapse.blockPaths == [ "/_synapse/admin" ];
    assert lib.hasInfix "client_max_body_size 100M"
      synapseSsoNode.config.services.nginx.virtualHosts."matrix.example.test".extraConfig;
    assert lib.hasInfix "proxy_read_timeout 600s"
      synapseSsoNode.config.services.nginx.virtualHosts."matrix.example.test".locations."/".extraConfig;
    assert builtins.length synapseSsoNode.config.infra.telemetry.synapse == 1;
    assert (builtins.head synapseSsoNode.config.infra.telemetry.synapse).labels.host == "test";
    assert
      (builtins.head synapseSsoNode.config.infra.telemetry.synapse).metrics_path == "/_synapse/metrics";
    assert (builtins.head synapseSsoNode.config.infra.telemetry.synapse).targets == [ "test:9000" ];
    assert lib.hasInfix "matrix.example.test:443" serverDelegation.return;
    assert builtins.elem "/var/lib/matrix-synapse" synapseSsoNode.config.infra.backup.paths;
    assert builtins.elem "/var/lib/matrix-synapse-backup" synapseSsoNode.config.infra.backup.paths;
    assert lib.hasInfix "pg_dump" backup.backupPrepareCommand;
    assert lib.hasInfix "e2e_one_time_keys_json" backup.backupPrepareCommand;
    assert assertSecret synapseSsoNode "synapse/registration-shared-secret" ./tests/sops/synapse.json
      "registration_shared_secret";
    assert assertSecret synapseSsoNode "sso/synapse-client-secret" ./tests/sops/synapse.json
      "oidc_client_secret";
    assert synapseSsoNode.config.sops.secrets."synapse/registration-shared-secret".mode == "0400";
    assert synapseSsoNode.config.sops.secrets."sso/synapse-client-secret".owner == "kanidm";
    assert synapseSsoNode.config.sops.secrets."sso/synapse-client-secret".mode == "0400";
    mkEvalCheck "synapse" synapseSsoNode;
  rust-storage-streamer =
    let
      filesService = rustStorageStreamerNode.config.services.rust-storage-streamer.files;
      s3Service = rustStorageStreamerNode.config.services.rust-storage-streamer.s3;
      filesUnit = rustStorageStreamerNode.config.systemd.services.rust-storage-streamer-files;
      s3Unit = rustStorageStreamerNode.config.systemd.services.rust-storage-streamer-s3;
      ingress = rustStorageStreamerNode.config.infra.ingress.rust-storage-streamer-s3;
      nginxLocation =
        rustStorageStreamerNode.config.services.nginx.virtualHosts."storage.example.test".locations."/";
    in
    assert assertSecret rustStorageStreamerNode "rust-storage-streamer/webhooks"
      ./tests/sops/rust-storage-streamer.json
      "webhooks";
    assert filesService.enable;
    assert filesService.listenAddress == "127.0.0.1";
    assert s3Service.enable;
    assert s3Service.listenAddress == "10.100.0.1";
    assert builtins.elem "webhooks:/run/secrets/rust-storage-streamer/webhooks"
      filesUnit.serviceConfig.LoadCredential;
    assert builtins.elem "webhooks:/run/secrets/rust-storage-streamer/webhooks"
      s3Unit.serviceConfig.LoadCredential;
    assert ingress.backend == [ "10.100.0.1:8081" ];
    assert lib.hasInfix "proxy_request_buffering off" ingress.locationExtraConfig;
    assert lib.hasInfix "client_max_body_size 0" nginxLocation.extraConfig;
    assert lib.any (
      rule: rule.port == 8081 && rule.allowedTags == [ "web-server" ]
    ) rustStorageStreamerNode.config.infra.security.acls;
    assert builtins.elem "/var/lib/rust-storage-streamer-files"
      rustStorageStreamerNode.config.infra.backup.paths;
    assert builtins.elem "/var/lib/rust-storage-streamer-s3"
      rustStorageStreamerNode.config.infra.backup.paths;
    mkEvalCheck "rust-storage-streamer" rustStorageStreamerNode;
  qbittorrent =
    let
      netnsUnit = qbittorrentNode.config.systemd.services.qbittorrent-netns;
      qbtUnit = qbittorrentNode.config.systemd.services.qbittorrent;
    in
    assert assertSecret qbittorrentNode "qbittorrent/wg.conf" ./tests/sops/qbittorrent.json "wgConf";
    assert qbittorrentNode.config.sops.secrets."qbittorrent/wg.conf".mode == "0400";
    assert assertSecret qbittorrentNode "qbittorrent/webui-password" ./tests/sops/qbittorrent.json
      "webui_password";
    assert builtins.elem "webui-password:/run/secrets/qbittorrent/webui-password" (
      lib.toList qbtUnit.serviceConfig.LoadCredential
    );
    assert lib.hasInfix "Password_PBKDF2" qbtUnit.preStart;
    assert qbittorrentNode.config.services.qbittorrent.enable;
    assert qbittorrentNode.config.services.qbittorrent.torrentingPort == 62000;
    assert qbtUnit.serviceConfig.NetworkNamespacePath == "/run/netns/qbittorrent";
    assert builtins.elem "/etc/netns/qbittorrent/resolv.conf:/etc/resolv.conf" (
      lib.toList qbtUnit.serviceConfig.BindReadOnlyPaths
    );
    assert builtins.elem "qbittorrent-netns.service" qbtUnit.bindsTo;
    # kill switch : la seule route par défaut du netns passe par le tunnel
    assert lib.hasInfix "route add default dev wg-qbt" netnsUnit.script;
    assert !lib.hasInfix "route add default dev veth" netnsUnit.script;
    assert
      qbittorrentNode.config.systemd.sockets.qbittorrent-webui.listenStreams == [ "10.100.0.1:8080" ];
    assert lib.any (
      rule: rule.port == 8080 && rule.allowedTags == [ "web-server" ]
    ) qbittorrentNode.config.infra.security.acls;
    assert
      qbittorrentNode.config.systemd.services.qbittorrent-exporter.environment.QBITTORRENT_BASE_URL
      == "http://10.200.0.2:8080";
    assert builtins.elem "webui-password:/run/secrets/qbittorrent/webui-password" (
      lib.toList qbittorrentNode.config.systemd.services.qbittorrent-exporter.serviceConfig.LoadCredential
    );
    assert lib.any (
      rule: rule.port == 8090 && rule.allowedTags == [ "prometheus" ]
    ) qbittorrentNode.config.infra.security.acls;
    assert builtins.length qbittorrentNode.config.infra.telemetry.qbittorrent == 1;
    assert (builtins.head qbittorrentNode.config.infra.telemetry.qbittorrent).targets == [
      "test:8090"
    ];
    assert (builtins.head qbittorrentNode.config.infra.telemetry.qbittorrent).labels.host == "test";
    assert builtins.elem ./nixos/modules/applications/dashboards/qbittorrent.json
      qbittorrentNode.config.infra.grafana.dashboards;
    assert qbittorrentNode.config.infra.ingress.qbittorrent.backend == [ "10.100.0.1:8080" ];
    assert builtins.elem "/var/lib/qBittorrent" qbittorrentNode.config.infra.backup.paths;
    mkEvalCheck "qbittorrent" qbittorrentNode;
  template =
    assert builtins.isAttrs templateParsed;
    assert builtins.pathExists ./template/inventory/hardware/vps1/hardware.nix;
    mkEvalCheck "template" templateNode;
  sops-wireguard =
    assert assertSecret wireguardSopsNode "wireguard/private-key" ./tests/sops/wireguard/test.json
      "privateKey";
    assert
      wireguardSopsNode.config.networking.wireguard.interfaces.wg0.privateKeyFile
      == "/run/secrets/wireguard/private-key";
    mkEvalCheck "sops-wireguard" wireguardSopsNode;
  sops-acme =
    assert assertSecret acmeIssuerSopsNode "acme/dns-credentials" ./tests/sops/acme.json
      "dnsCredentials";
    assert assertSecret acmeConsumerSopsNode "acme/syncer-private-key" ./tests/sops/acme-syncer.json
      "privateKey";
    assert acmeIssuerSopsNode.config.sops.secrets."acme/dns-credentials".owner == "acme";
    assert acmeIssuerSopsNode.config.sops.secrets."acme/dns-credentials".group == "acme";
    assert acmeConsumerSopsNode.config.sops.secrets."acme/syncer-private-key".mode == "0400";
    mkEvalCheck "sops-acme" acmeIssuerSopsNode;
  sops-grafana =
    assert assertSecret grafanaSopsNode "grafana/password" ./tests/sops/grafana.json "password";
    assert assertSecret grafanaSopsNode "grafana/secret" ./tests/sops/grafana.json "grafana_secret";
    assert assertSecret grafanaSopsNode "sso/grafana-client-secret" ./tests/sops/grafana.json
      "oidc_client_secret";
    assert grafanaSopsNode.config.sops.secrets."sso/grafana-client-secret".owner == "kanidm";
    mkEvalCheck "sops-grafana" grafanaSopsNode;
  sops-kanidm =
    assert assertSecret grafanaSopsNode "kanidm/idm-admin-password" ./tests/sops/kanidm.json
      "idm_admin_password";
    assert grafanaSopsNode.config.sops.secrets."kanidm/idm-admin-password".owner == "kanidm";
    assert grafanaSopsNode.config.sops.secrets."kanidm/idm-admin-password".mode == "0400";
    mkEvalCheck "sops-kanidm" grafanaSopsNode;
  sops-docker-registry =
    assert assertSecret registrySopsNode "docker-registry/accounts" ./tests/sops/docker-registry.json
      "accounts";
    mkEvalCheck "sops-docker-registry" registrySopsNode;
  sops-restic =
    assert assertSecret resticSopsNode "restic/repository" ./tests/sops/restic.json "repository";
    assert assertSecret resticSopsNode "restic/password" ./tests/sops/restic.json "password";
    assert assertSecret resticSopsNode "restic/env" ./tests/sops/restic.json "env";
    mkEvalCheck "sops-restic" resticSopsNode;
  sops-rclone =
    assert assertSecret rcloneSopsNode "rclone/test" ./tests/sops/rclone-sync.json "test";
    assert rcloneSopsNode.config.infra.rcloneSync.mounts.test.configFile == null;
    assert lib.hasInfix "/run/secrets/rclone/test"
      rcloneSopsNode.config.systemd.services.rclone-config-test.script;
    mkEvalCheck "sops-rclone" rcloneSopsNode;
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
  sops-script =
    checkPkgs.runCommand "sops-script"
      {
        nativeBuildInputs = [
          checkPkgs.bash
          checkPkgs.coreutils
          checkPkgs.gnugrep
          checkPkgs.gnused
          checkPkgs.jq
          checkPkgs.ripgrep
        ];
      }
      ''
        bash ${./scripts/test-sops-project.sh}
        touch "$out"
      '';
  script-packages = checkPkgs.symlinkJoin {
    name = "script-packages";
    paths = lib.attrValues (builtins.removeAttrs self.packages.x86_64-linux [ "default" ]);
  };
}
