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
  tag = "applications/reposilite";
  port = 5002;
  enabled = services.hasTag tag;
in
{
  options.infra.reposilite = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique de l'instance Reposilite (ex: https://repo.example.com).";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }
    (lib.mkIf enabled {
      services.reposilite = {
        enable = true;
        workingDirectory = "/var/lib/reposilite";

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

      infra.backup.paths = [ "/var/lib/reposilite" ];

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
    {
      infra.telemetry."reposilite" = map (host: {
        targets = [ "${host}:${toString port}" ];
        labels = {
          host = host;
        };
      }) (services.getHostsByTag tag);
    }
    (lib.mkIf (config.infra.reposilite.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."reposilite" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] config.infra.reposilite.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);
        blockPaths = [ "/metrics" ];
      };
    })
    (lib.mkIf (services.getHostsByTag tag != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/reposilite.json ];
    })
  ];
}
