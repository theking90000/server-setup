{
  config,
  pkgs,
  lib,
  ...
}:

let
  wg = import ../wg-peers.nix;

  cfg = config.profile.reposilite;
in
{
  options.profile.reposilite = {
    enable = lib.mkEnableOption "Activer Reposilite sur ce serveur";
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = wg.wgIp;
      description = "L'IP sur laquelle Reposilite écoutera.";
    };

    reposiliteHost = lib.mkOption {
      type = lib.types.str;
      default = wg.wgIp;
      description = "L'hostname ou l'IP utilisée par Prometheus pour scraper Reposilite.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      services.reposilite = {
        enable = true;
        workingDirectory = "/var/lib/reposilite";

        settings = {
          port = 5002;
          hostname = cfg.listenAddress;
        };

        plugins = with pkgs.reposilitePlugins; [
          checksum
          prometheus
        ];
      };

      systemd.services.reposilite.environment = {
        REPOSILITE_PROMETHEUS_USER = "user";
        REPOSILITE_PROMETHEUS_PASSWORD = "password";
      };

      profile.backup.paths = [ "/var/lib/reposilite" ];

      # Ouverture du port pour Docker-Registry (via VPN uniquement)
      networking.firewall.interfaces.wg0.allowedTCPPorts = [
        5000
        5001
      ];
    })
    ({
      services.prometheus.scrapeConfigs = [
        {
          job_name = "reposilite";
          scrape_interval = "15s";

          static_configs = [
            {
              targets = [ "${cfg.reposiliteHost}:5002" ];
            }
          ];

          basic_auth = {
            username = "user";
            password = "password";
          };
        }
      ];
    })
  ];
}
