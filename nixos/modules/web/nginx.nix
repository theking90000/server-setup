{
  config,
  pkgs,
  lib,
  services,
  ...
}:

let
  enabled = services.hasTag "web-server";

  getVal = local: global: if local != null then local else global;
in
{
  config = lib.mkMerge [
    # Configurer NGinx si activé
    (lib.mkIf enabled {
      services.nginx = {
        enable = true;

        # Virtual Host Traffic Module
        additionalModules = [ pkgs.nginxModules.vts ];

        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;

        serverTokens = false;

        appendHttpConfig = ''
          vhost_traffic_status_zone;

          # Optionnel : Si tu veux des stats par code de réponse (2xx, 3xx, 4xx, 5xx)
          # vhost_traffic_status_filter_by_host on;

          vhost_traffic_status_histogram_buckets 0.005 0.01 0.05 0.1 0.5 1 5 10;
        '';
      };

      users.users.nginx.extraGroups =
        lib.optional (builtins.hasAttr "acme" config.users.groups) "acme"
        ++ lib.optional (builtins.hasAttr "cert-syncer" config.users.groups) "cert-syncer";

      # Par défaut, on rejette toutes les connexions non gérées
      services.nginx.virtualHosts."_" = {
        default = true;
        rejectSSL = true;
        http2 = false;

        locations."/" = {
          return = "444";
        };
      };

      services.nginx.virtualHosts."stats.localhost" = {
        listen = [
          {
            addr = services.getVpnIp;
            port = 9113;
          }
        ];

        locations."/metrics" = {
          extraConfig = ''
            vhost_traffic_status_display;
            vhost_traffic_status_display_format prometheus;
          '';
        };
      };

      networking.firewall.allowedTCPPorts = [
        80
        443
      ];

      infra.security.acls = [
        {
          port = 9113;
          allowedTags = [
            "prometheus"
          ];
          description = "NGINX VTS Metrics";
        }
      ];
    })
    (lib.mkIf enabled {

      # Configuration de l'ingress puisqu'on a choisi NGINX comme reverse proxy
      services.nginx.upstreams = lib.mapAttrs (name: site: {
        servers = lib.genAttrs site.backend (addr: { });
      }) config.infra.ingress;

      infra.acme.domains = lib.flatten (
        lib.mapAttrsToList (
          name: site:
          lib.optional (site.sslCertificate == null) {
            domain = site.domain;
          }
        ) config.infra.ingress
      );

      services.nginx.virtualHosts = lib.mapAttrs (name: site: {
        serverName = site.domain;

        forceSSL = true;

        # useACMEHost = getVal site.sslCertificate site.domain;
        sslCertificate = "/var/lib/acme/${getVal site.sslCertificate site.domain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${getVal site.sslCertificate site.domain}/key.pem";
        sslTrustedCertificate = "/var/lib/acme/${getVal site.sslCertificate site.domain}/chain.pem";

        extraConfig = ''
          error_log /var/log/nginx/${name}_error.log;
          access_log /var/log/nginx/${name}_access.log;
        '';

        locations = {
          "/" = {
            # On proxy vers l'upstream qu'on a créé juste au-dessus
            # Le nom de l'upstream est le nom de la clé (ex: "grafana")
            proxyPass = "http://${name}";

            # Les headers classiques pour ne pas casser les websockets
            proxyWebsockets = true;
          };
        }
        # Bloquer les chemins sensibles définis dans la configuration de l'ingress
        //
          lib.mapAttrs
            (path: _: {
              return = "403";
            })
            (
              lib.listToAttrs (
                map (p: {
                  name = p;
                  value = null;
                }) site.blockPaths or [ ]
              )
            );

      }) config.infra.ingress;

    })
    {

      infra.telemetry."nginx" = map (host: {
        targets = [ "${host}:9113" ];
        labels = {
          host = host;
        };
      }) (services.getHostsByTag "web-server");

    }
  ];
}
