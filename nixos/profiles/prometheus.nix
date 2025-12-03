{
  config,
  pkgs,
  lib,
  ...
}:

let
  wg = import ../wg-peers.nix;

  cfg = config.profile.prometheus;
in
{
  # 1. DÉCLARATION DES PARAMÈTRES (L'API)
  options.profile.prometheus = {
    enable = lib.mkEnableOption "Activer Prometheus sur ce serveur";

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = wg.wgIp;
      description = "L'IP sur laquelle Prometheus écoutera.";
    };
  };

  config = lib.mkIf cfg.enable {

    services.prometheus = {
      enable = true;
      port = 9090;
      listenAddress = cfg.listenAddress;

      retentionTime = "15d";

      scrapeConfigs = [
        {
          job_name = "node-mesh";
          scrape_interval = "15s";

          # C'est ici qu'on injecte la liste générée
          static_configs = lib.mapAttrsToList (name: _: {
            targets = [ "${name}:9100" ];
            labels = {
              host = name;
            };
          }) wg.ips;

          relabel_configs = [
            {
              source_labels = [ "__address__" ];
              regex = "(.+):9100";
              target_label = "instance";
              replacement = "$1";
            }
          ];

          # Bonus : Ajouter des labels pour faire joli dans Grafana
          #labels = {
          #  env = "production";
          #  region = "ovh-europe";
          #};

        }
      ];
    };

    # Ouverture du port pour Grafana (via VPN uniquement)
    networking.firewall.interfaces.wg0.allowedTCPPorts = [ 9090 ];
  };
}
