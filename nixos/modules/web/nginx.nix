{
  config,
  pkgs,
  lib,
  services,
  ...
}:

let
  cfg = config.profile.nginx;

  enabled = services.hasTag "web-server";
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

      networking.firewall.allowedTCPPorts = [
        80
        443
      ];

      users.users.nginx.extraGroups =
        lib.optional (builtins.hasAttr "acme" config.users.groups) "acme"
        ++ lib.optional (builtins.hasAttr "cert-syncer" config.users.groups) "cert-syncer";

      # On ouvre le port de monitoring UNIQUEMENT sur le VPN
      networking.firewall.interfaces.wg0.allowedTCPPorts = [ 9113 ];

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
    })
    ({
      infra.telemetry."nginx" = builtins.map (host: {
        targets = [ "${host}:9113" ];
        labels = {
          host = host;
        };
      }) (services.getHostsByTag "web-server");
    })
  ];
}
