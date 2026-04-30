# -------------------------------------------------------------------------
# docker-registry.nix — Registre Docker privé
#
# Déploie un registre Docker écoutant sur l'IP VPN (port 5000) avec
# authentification htpasswd. Exporte les métriques Prometheus sur le port
# 5001. Si une URL publique est configurée, déclare automatiquement
# les règles ACL + ingress Nginx + télémétrie Prometheus.
#
# Tags requis : `applications/docker-registry`
# Secrets     : `infra.dockerRegistry.accounts` (déployé via Colmena)
# -------------------------------------------------------------------------
{
  config,
  services,
  lib,
  ops,
  ...
}:

let
  tag = "applications/docker-registry";
  enabled = services.hasTag tag;
in
{
  options.infra.dockerRegistry = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique du registre Docker (ex: https://registry.example.com).";
    };

    accounts = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Fichier htpasswd pour l'authentification du registre Docker.";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }
    (lib.mkIf enabled {
      deployment.keys = ops.mkSecretKeys "docker-registry" config.infra.dockerRegistry [ "accounts" ];

      systemd.services.docker-registry.serviceConfig = {
        LoadCredential = [
          "admin_pwd:/var/lib/secrets/docker-registry/accounts"
        ];
      };

      services.dockerRegistry = {
        enable = true;
        port = 5000;
        listenAddress = services.getVpnIp;

        openFirewall = false;

        storagePath = "/var/lib/docker-registry";

        enableDelete = true;
        enableGarbageCollect = true;

        extraConfig = {
          auth = {
            htpasswd = {
              realm = "Registry";
              path = "/run/credentials/docker-registry.service/admin_pwd";
            };
          };

          http = {
            debug = {
              addr = "${services.getVpnIp}:5001";
              prometheus = {
                enabled = true;
                path = "/metrics";
              };
            };
          };
        };
      };

      infra.backup.paths = [ "/var/lib/docker-registry" ];

      infra.security.acls = [
        {
          port = 5000;
          allowedTags = [ "web-server" ];
          description = "Docker registry";
        }
        {
          port = 5001;
          allowedTags = [ "prometheus" ];
          description = "Docker registry metrics";
        }
      ];

    })
    (lib.mkIf (config.infra.dockerRegistry.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."docker-registry" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] config.infra.dockerRegistry.url;
        backend = map (ip: "${ip}:5000") (services.getVpnIpsByTag tag);
      };
    })
    {
      infra.telemetry."docker-registry" = map (host: {
        targets = [ "${host}:5001" ];
        labels = {
          host = host;
        };
      }) (services.getHostsByTag tag);
    }
  ];
}
