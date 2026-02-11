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
  options.services.nginx.virtualHosts = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, config, ... }:
        {

          options.profile = {
            useHTTPS = lib.mkEnableOption "Activer HTTPS via le certificat centralisé";

            certName = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "Nom du dossier du certificat (par défaut le wildcard)";
            };

            blockMetrics = lib.mkEnableOption "Bloquer l'accès aux endpoints de métriques (ex: /metrics, /stats, etc.)";
          };

          # La logique : Si useHTTPS est true, on injecte la config SSL standard
          config = lib.mkMerge [
            (lib.mkIf config.profile.useHTTPS {
              forceSSL = true;

              # La magie de l'injection automatique
              sslCertificate = "/var/lib/acme/${
                lib.replaceStrings [ "*" ] [ "_" ] config.profile.certName
              }/fullchain.pem";
              sslCertificateKey = "/var/lib/acme/${
                lib.replaceStrings [ "*" ] [ "_" ] config.profile.certName
              }/key.pem";
            })

            (lib.mkIf config.profile.blockMetrics {
              locations."/metrics" = {
                return = "403";
              };
            })
          ];

        }
      )
    );
  };

  config = lib.mkMerge [
    (lib.mkIf enabled {

      # Par défaut, on rejette toutes les connexions non gérées
      services.nginx.virtualHosts."_" = {
        default = true;
        rejectSSL = true;
        http2 = false;

        locations."/" = {
          return = "444";
        };
      };

      services.nginx = {
        enable = true;
        # Virtual Host Traffic Module
        additionalModules = [ pkgs.nginxModules.vts ];

        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;

        serverTokens = false;

        # 2. MONITORING (Stub Status)
        # On ajoute un serveur interne invisible de l'extérieur
        # Il sert à exposer les métriques brutes
        appendHttpConfig = ''
          vhost_traffic_status_zone;

          # Optionnel : Si tu veux des stats par code de réponse (2xx, 3xx, 4xx, 5xx)
          # vhost_traffic_status_filter_by_host on;

          vhost_traffic_status_histogram_buckets 0.005 0.01 0.05 0.1 0.5 1 5 10;

          server {
            listen ${wg.wgIp}:9113;
            server_name stats.localhost;

            location /metrics {
              vhost_traffic_status_display;
              vhost_traffic_status_display_format prometheus;
            }
          }
        '';
      };

      networking.firewall.allowedTCPPorts = [
        80
        443
      ];

      users.users.nginx.extraGroups =
        lib.optional (builtins.hasAttr "acme" config.users.groups) "acme"
        ++ lib.optional (builtins.hasAttr "cert-syncer" config.users.groups) "cert-syncer";

      # # L'exporter Prometheus (qui lit le stub_status ci-dessus)
      # services.prometheus.exporters.nginx = {
      #   enable = true;
      #   port = 9113; # Port par défaut
      #   listenAddress = wg.wgIp;

      #   scrapeUri = "http://127.0.0.1:8080/stub_status";
      #   # On s'assure que l'exporter ne sort pas sur internet
      #   openFirewall = false;
      # };

      # On ouvre le port de monitoring UNIQUEMENT sur le VPN
      networking.firewall.interfaces.wg0.allowedTCPPorts = [ 9113 ];

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
