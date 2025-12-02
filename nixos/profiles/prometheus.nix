{ config, pkgs, lib, ... }:

let
  wg = import ../wg-peers.nix;

  nodeTargets = lib.mapAttrsToList (name: _: "${name}:9100") wg.ips;

  cfg = config.profile.prometheus;
in
{
  # 1. DÉCLARATION DES PARAMÈTRES (L'API)
  options.profile.prometheus = {
    enable = lib.mkEnableOption "Activer Prometheus sur ce serveur";
  };

  config = lib.mkIf cfg.enable {
    
    services.prometheus =  {
      enable = true;
      port = 9090;

      scrapeConfigs = [
        {
          job_name = "node-mesh";
          scrape_interval = "15s";
          
          # C'est ici qu'on injecte la liste générée
          static_configs = [
            {
              targets = nodeTargets;
              
              # Bonus : Ajouter des labels pour faire joli dans Grafana
              #labels = {
              #  env = "production";
              #  region = "ovh-europe";
              #};
            }
          ];
        }
      ];
    };

    # Ouverture du port pour Grafana (via VPN uniquement)
    networking.firewall.interfaces.wg0.allowedTCPPorts = [ 9090 ];
  };
}