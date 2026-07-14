# -------------------------------------------------------------------------
# reposilite.nix — Gestionnaire de dépôts Maven
#
# Déploie Reposilite écoutant sur l'IP VPN (port 5002) avec les plugins
# checksum et prometheus. Si une URL publique est configurée, déclare
# automatiquement les ACLs, l'ingress Nginx et la télémétrie.
#
# Tags requis : `applications/reposilite`
# -------------------------------------------------------------------------
{
  config,
  services,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.infra.reposilite;
  tag = "applications/reposilite";
  enabled = services.hasTag tag;
  port = 5002;
  dataDir = "/var/lib/reposilite";
in
{
  # Public API
  options.infra.reposilite = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique de l'instance Reposilite (ex: https://repo.example.com).";
    };
  };

  config = lib.mkMerge [
    # Module contract
    { infra.registeredTags = [ tag ]; }

    # Local configuration
    (lib.mkIf enabled {
      services.reposilite = {
        enable = true;
        workingDirectory = dataDir;

        openFirewall = false;

        settings = {
          port = port;
          hostname = services.getVpnIp;
        };

        plugins = with pkgs.reposilitePlugins; [
          checksum
          prometheus
        ];
      };

      systemd.services.reposilite.environment = {
        REPOSILITE_PROMETHEUS_USER = "user";
        REPOSILITE_PROMETHEUS_PASSWORD = "password";
      };

      infra.backup.paths = [ dataDir ];

      infra.security.acls = [
        {
          port = port;
          allowedTags = [
            "web-server"
            "prometheus"
          ];
          description = "Reposilite";
        }
      ];

    })

    # Fleet-wide contributions
    {
      infra.telemetry."reposilite" = map (host: {
        targets = [ "${host}:${toString port}" ];
        labels = { inherit host; };
        basic_auth = {
          username = "user";
          password = "password";
        };
      }) (services.getHostsByTag tag);
    }
    (lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."reposilite" = {
        url = cfg.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);
        blockPaths = [ "/metrics" ];
      };
    })
    (lib.mkIf (services.getHostsByTag tag != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/reposilite.json ];
    })
  ];
}
