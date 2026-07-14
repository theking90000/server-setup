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
  cfg = config.infra.gitea;
  tag = "applications/gitea";
  enabled = services.hasTag tag;
  port = 3003;
  dataDir = "/var/lib/gitea";
in
{
  # Public API
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
    # Module contract
    { infra.registeredTags = [ tag ]; }

    # Local configuration
    (lib.mkIf enabled {
      services.gitea = {
        enable = true;
        stateDir = dataDir;

        settings = {
          server = {
            HTTP_PORT = port;
            HTTP_ADDR = services.getVpnIp;
          }
          // lib.optionalAttrs (cfg.url != null) {
            ROOT_URL = cfg.url;
          };

          metrics = {
            ENABLED = true;
          };

          service = {
            DISABLE_REGISTRATION = !cfg.registrationEnabled;
          };
        };
      };

      infra.backup.paths = [ dataDir ];

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

    # Fleet-wide contributions
    {
      infra.telemetry."gitea" = map (host: {
        targets = [ "${host}:${toString port}" ];
        labels = { inherit host; };
      }) (services.getHostsByTag tag);
    }
    (lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."gitea" = {
        url = cfg.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);
        blockPaths = [ "/metrics" ];
      };
    })
    (lib.mkIf (services.getHostsByTag tag != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/gitea.json ];
    })
  ];
}
