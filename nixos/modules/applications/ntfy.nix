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
  cfg = config.infra.ntfy;
  tag = "applications/ntfy";
  enabled = services.hasTag tag;
  port = 3004;
  dataDir = "/var/lib/ntfy-sh/user.db";
in
{
  # Public API
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
    # Module contract
    { infra.registeredTags = [ tag ]; }

    # Local configuration
    (lib.mkIf enabled {
      services.ntfy-sh = {
        enable = true;

        settings = {
          listen-http = "${services.getVpnIp}:${toString port}";
          # NixOS declares base-url as required; use the private endpoint when
          # no public URL is configured.
          base-url = if cfg.url != null then cfg.url else "http://${services.getVpnIp}:${toString port}";
          behind-proxy = cfg.url != null;
          enable-metrics = true;
        }
        // lib.optionalAttrs (cfg.upstream-base-url != null) {
          upstream-base-url = cfg.upstream-base-url;
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

    # Fleet-wide contributions
    {
      infra.telemetry."ntfy" = map (host: {
        targets = [ "${host}:${toString port}" ];
        labels = { inherit host; };
      }) (services.getHostsByTag tag);
    }
    (lib.mkIf (services.getVpnIpsByTag tag != [ ] && cfg.url != null) {
      infra.ingress."ntfy" = {
        url = cfg.url;
        proxyTo = map (ip: "http://${ip}:${toString port}") (services.getVpnIpsByTag tag);
        routes.metrics = {
          path = "/metrics";
          nginx.return = "403";
        };
      };
    })
    (lib.mkIf (services.getHostsByTag tag != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/ntfy.json ];
    })
  ];
}
