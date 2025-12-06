{
  config,
  pkgs,
  lib,
  ...
}:

let
  # La logique magique :
  # On récupère les noms des vhosts définis.
  # On vérifie s'il y en a plus de 0.
  cfg = config.profile.nginx;
in
{
  options.profile.nginx = {
    enable = lib.mkEnableOption "Activer la configuration Nginx de base";
  };

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

  # On n'active ces réglages QUE si Nginx est activé quelque part ailleurs
  # (par exemple via profile.grafana ou un vhost manuel)
  config = lib.mkIf cfg.enable {

    # Ajout d'un vhost par défaut "poubelle"
    services.nginx.virtualHosts."_" = {
      # C'est lui le patron par défaut si aucun autre domaine ne correspond
      default = true;

      rejectSSL = true;

      # On refuse explicitement HTTP/2 pour réduire la surface d'attaque sur ce vhost poubelle
      http2 = false;

      locations."/" = {
        # "Tais-toi et raccroche"
        return = "444";
      };
    };

    # 1. CONFIGURATION DE BASE (Les bonnes pratiques)
    services.nginx = {
      enable = true;

      # Optimisations pour la performance
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      # Sécurité : On cache la version de Nginx
      serverTokens = false;

      # 2. MONITORING (Stub Status)
      # On ajoute un serveur interne invisible de l'extérieur
      # Il sert à exposer les métriques brutes
      #   appendHttpConfig = ''
      #     server {
      #       listen 127.0.0.1:8080;
      #       server_name localhost;

      #       location /stub_status {
      #         stub_status on;
      #         access_log off;
      #         allow 127.0.0.1;
      #         deny all;
      #       }
      #     }
      #   '';
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];

    users.groups.acme = { };
    users.groups.cert-syncer = { };

    users.users.nginx.extraGroups = [
      "acme"
      "cert-syncer"
    ];

    # # L'exporter Prometheus (qui lit le stub_status ci-dessus)
    # services.prometheus.exporters.nginx = {
    #   enable = true;
    #   port = 9113; # Port par défaut
    #   scrapeUri = "http://127.0.0.1:8080/stub_status";
    #   # On s'assure que l'exporter ne sort pas sur internet
    #   openFirewall = false;
    # };

    # On ouvre le port de monitoring UNIQUEMENT sur le VPN
    # networking.firewall.interfaces.wg0.allowedTCPPorts = [ 9113 ];

  };
}
