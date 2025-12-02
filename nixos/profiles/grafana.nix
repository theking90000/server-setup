{ config, pkgs, lib, ... }:

let
  # On raccourcit l'accès aux fonctions
  cfg = config.profile.grafana;
in
{
  # 1. DÉCLARATION DES PARAMÈTRES (L'API)
  options.profile.grafana = {
    enable = lib.mkEnableOption "Activer Grafana sur ce serveur";

    prometheusHost = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      description = "Le nom d'hôte ou l'IP du serveur Prometheus";
    };
    
    adminPasswordFile = lib.mkOption {
      type = lib.types.path;
      description = "Chemin vers le fichier contenant le mdp admin";
    };
  };

  # 2. LA CONFIGURATION (L'IMPLÉMENTATION)
  # Ce bloc ne s'active QUE si enable = true
  config = lib.mkIf cfg.enable {
    
    services.grafana = {
      enable = true;
      settings.server.http_port = 3000;
      
      # Utilisation du paramètre pour le mot de passe
      settings.security.admin_password_file = cfg.adminPasswordFile;

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
  };
}