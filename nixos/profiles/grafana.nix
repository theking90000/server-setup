{
  config,
  pkgs,
  lib,
  ...
}:

let
  wg = import ../wg-peers.nix;

  # On raccourcit l'accès aux fonctions
  cfg = config.profile.grafana;
in
{
  # 1. DÉCLARATION DES PARAMÈTRES (L'API)
  options.profile.grafana = {
    enable = lib.mkEnableOption "Activer Grafana sur ce serveur";

    prometheusHost = lib.mkOption {
      type = lib.types.str;
      default = wg.wgIp;
      description = "Le nom d'hôte ou l'IP du serveur Prometheus";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = wg.wgIp;
      description = "L'IP sur laquelle Grafana écoutera.";
    };

    adminPasswordFile = lib.mkOption {
      type = lib.types.path;
      description = "Chemin vers le fichier contenant le mdp admin";
      default = "/var/lib/secrets/grafana-admin-password";
    };

    expose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Exposer Grafana sur le reverse-proxy (nginx)";
    };

    exposeHost = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Nom de domaine à utiliser pour accéder à Grafana (via le reverse-proxy)";
    };

    exposeCert = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Certificat SSL à utiliser pour Grafana (via le reverse-proxy)";
    };

    grafanaHost = lib.mkOption {
      type = lib.types.str;
      default = wg.wgIp;
      description = "Nom d'hôte ou IP de Grafana pour le reverse-proxy";
    };

    rootUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://${wg.wgIp}:3000/";
      description = "URL racine de Grafana, utilisée pour les liens et les redirections.";
    };

  };

  # 2. LA CONFIGURATION (L'IMPLÉMENTATION)
  # On fusionne les deux blocs conditionnels avec mkMerge
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {

      systemd.services.grafana.serviceConfig = {
        # Syntaxe : "ID_DU_CREDENTIAL : CHEMIN_SOURCE"
        LoadCredential = [
          "admin_pwd:/var/lib/secrets/grafana-admin-password"
        ];
      };

      services.grafana = {
        enable = true;
        settings.server.http_port = 3000;
        settings.server.http_addr = cfg.listenAddress;

        settings.server.root_url = cfg.rootUrl;

        # Grafana ne lit pas la source, il lit le "Passe-Plat"
        # Le chemin standard est : /run/credentials/<nom_du_service>/<ID>
        settings.security = {
          admin_password = "$__file{/run/credentials/grafana.service/admin_pwd}";

          admin_user = "admin";
        };

        provision.enable = true;
        provision.datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            # Utilisation du paramètre ici !
            url = "http://${cfg.prometheusHost}:9090";
          }
        ];
      };

      # On ouvre le port (si on veut)
      networking.firewall.allowedTCPPorts = [ 3000 ];

      # On ajoute le dossier Grafana aux backups
      profile.backup.paths = [ "/var/lib/grafana" ];
    })

    (lib.mkIf cfg.expose {
      services.nginx.upstreams.grafana.servers = {
        "${cfg.grafanaHost}:3000" = { };
      };

      services.nginx.virtualHosts."grafana" = {
        serverName = cfg.exposeHost;

        profile.useHTTPS = true;
        profile.certName = cfg.exposeCert;

        extraConfig = ''
          error_log /var/log/nginx/grafana_error.log;
          access_log /var/log/nginx/grafana_access.log;
        '';

        locations."/" = {
          proxyPass = "http://grafana";

          # INDISPENSABLE pour Grafana (les graphiques en temps réel utilisent des WebSockets)
          proxyWebsockets = true;
        };
      };
    })
  ];
}
