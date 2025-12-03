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
  };

  # 2. LA CONFIGURATION (L'IMPLÉMENTATION)
  # Ce bloc ne s'active QUE si enable = true
  config = lib.mkIf cfg.enable {

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
  };
}
