# -------------------------------------------------------------------------
# gitea.nix — Serveur Git auto-hébergé
#
# Déploie Gitea écoutant sur l'IP VPN (port 3003) avec métriques
# Prometheus activées. Si une URL publique est configurée, déclare
# automatiquement les ACLs, l'ingress Nginx et la télémétrie.
#
# Tags requis : `applications/gitea`
# -------------------------------------------------------------------------
{
  config,
  services,
  lib,
  ...
}:

let
  tag = "applications/gitea";
  port = 3003;
  enabled = services.hasTag tag;
in
{
  options.infra.gitea = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique de l'instance Gitea (ex: https://git.example.com).";
    };

    registrationEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Autoriser l'inscription libre des utilisateurs.";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }
    (lib.mkIf enabled {
      services.gitea = {
        enable = true;
        stateDir = "/var/lib/gitea";

        settings = {
          server = {
            ROOT_URL = "${config.infra.gitea.url}";
            HTTP_PORT = port;
            HTTP_ADDR = services.getVpnIp;
          };

          metrics = {
            ENABLED = true;
          };

          service = {
            DISABLE_REGISTRATION = !config.infra.gitea.registrationEnabled;
          };
        };
      };

      infra.backup.paths = [ "/var/lib/gitea" ];

      infra.security.acls = [
        {
          port = port;
          allowedTags = [
            "web-server"
            "prometheus"
          ];
          description = "Gitea";
        }
      ];

    })
    {
      infra.telemetry."gitea" = map (host: {
        targets = [ "${host}:${toString port}" ];
        labels = {
          host = host;
        };
      }) (services.getHostsByTag tag);
    }
    (lib.mkIf (config.infra.gitea.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."gitea" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] config.infra.gitea.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);
        blockPaths = [ "/metrics" ];
      };
    })
  ];
}
