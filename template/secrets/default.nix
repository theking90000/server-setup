{
  config,
  lib,
  services,
  ...
}:

let
  secret = file: key: {
    sopsFile = ./. + "/${file}.json";
    inherit key;
  };
  has = tag: services.hasTag tag;
  localSsoClients = lib.filterAttrs (
    _: client: !client.public && (has "kanidm" || has client.serviceTag)
  ) config.infra.sso;
in
{
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  sops.secrets = lib.mkMerge [
    {
      "wireguard/private-key" = secret "wireguard/${config.infra.nodeName}" "privateKey" // {
        mode = "0400";
      };
      "acme/syncer-private-key" = lib.mkIf (!has "acme-issuer") (
        secret "acme-syncer" "privateKey" // { mode = "0400"; }
      );
      "acme/dns-credentials" = lib.mkIf (has "acme-issuer") (
        secret "acme" "dnsCredentials"
        // {
          owner = "acme";
          group = "acme";
        }
      );
      "docker-registry/accounts" = lib.mkIf (has "applications/docker-registry") (
        secret "docker-registry" "accounts"
      );
      "grafana/password" = lib.mkIf (has "grafana") (secret "grafana" "password");
      "grafana/secret" = lib.mkIf (has "grafana") (secret "grafana" "grafana_secret");
      "kanidm/idm-admin-password" = lib.mkIf (has "kanidm" && config.infra.sso != { }) (
        secret "kanidm" "idm_admin_password"
        // {
          owner = "kanidm";
          mode = "0400";
        }
      );
      "restic/repository" = lib.mkIf (has "backup") (secret "restic" "repository");
      "restic/password" = lib.mkIf (has "backup") (secret "restic" "password");
      "restic/env" = lib.mkIf (has "backup") (secret "restic" "env");
    }
    (lib.mapAttrs' (
      name: _:
      lib.nameValuePair "sso/${name}-client-secret" (
        secret name "oidc_client_secret"
        // {
          owner = if has "kanidm" then "kanidm" else "root";
          mode = "0400";
        }
      )
    ) localSsoClients)
  ];

  infra.wireguard.privateKeyFile = config.sops.secrets."wireguard/private-key".path;

  infra.acme = {
    certSyncerPrivateKeyFile = "/run/secrets/acme/syncer-private-key";
    certSyncerPublicKey = builtins.readFile ../inventory/keys/syncer.key.pub;
  };
  infra.acme.dnsCredentialsFile = "/run/secrets/acme/dns-credentials";

  infra.dockerRegistry.accountsFile = "/run/secrets/docker-registry/accounts";

  infra.grafana = {
    passwordFile = "/run/secrets/grafana/password";
    grafanaSecretFile = "/run/secrets/grafana/secret";
  };

  infra.restic = {
    repositoryFile = "/run/secrets/restic/repository";
    passwordFile = "/run/secrets/restic/password";
    envFile = "/run/secrets/restic/env";
  };

  # Les montages rclone ont des noms propres au projet. Déclare ici leur
  # sops.secrets.<name> et leur infra.rcloneSync.mounts.<name>.configFile.
}
