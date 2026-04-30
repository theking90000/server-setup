# -------------------------------------------------------------------------
# ntfy.nix — Serveur de notifications push
#
# Déploie ntfy écoutant sur l'IP VPN (port 3004) derrière un proxy,
# avec métriques Prometheus activées. Si une URL publique est configurée,
# déclare automatiquement les ACLs, l'ingress Nginx et la télémétrie.
#
# La configuration est optionnelle (le module fonctionne sans si le
# fichier de config n'existe pas dans le repo privé).
#
# Tags requis : `applications/ntfy`
# -------------------------------------------------------------------------
{
  config,
  services,
  lib,
  ...
}:

let
  tag = "applications/ntfy";
  port = 3004;
  dataDir = "/var/lib/ntfy-sh/user.db";
  enabled = services.hasTag tag;
in
{
  options.infra.ntfy = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique du serveur ntfy (ex: https://ntfy.example.com).";
    };

    upstream-base-url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL upstream pour les notifications push (ex: https://ntfy.sh).";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }
    (lib.mkIf enabled {
      services.ntfy-sh = {
        enable = true;

        settings = {
          listen-http = "${services.getVpnIp}:${toString port}";
          base-url = config.infra.ntfy.url;

          behind-proxy = true;

          enable-metrics = true;

          upstream-base-url = config.infra.ntfy.upstream-base-url;
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
          description = "NTFY";
        }
      ];

    })
    {
      infra.telemetry."ntfy" = map (host: {
        targets = [ "${host}:${toString port}" ];
        labels = {
          host = host;
        };
      }) (services.getHostsByTag tag);
    }
    (lib.mkIf (config.infra.ntfy.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."ntfy" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] config.infra.ntfy.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);
        blockPaths = [ "/metrics" ];
      };
    })
    (lib.mkIf (services.getHostsByTag tag != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/ntfy.json ];
    })
  ];
}
