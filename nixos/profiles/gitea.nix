{
  config,
  pkgs,
  lib,
  ...
}:

let
  wg = import ../wg-peers.nix;

  cfg = config.profile.gitea;
in
{
  options.profile.gitea = {
    enable = lib.mkEnableOption "Activer Gitea sur ce serveur";
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = wg.wgIp;
      description = "L'IP sur laquelle Gitea écoutera.";
    };

    giteaHost = lib.mkOption {
      type = lib.types.str;
      default = wg.wgIp;
      description = "L'hostname ou l'IP utilisée par Prometheus pour scraper Gitea.";
    };

    expose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Exposer Gitea sur le reverse-proxy (nginx)";
    };

    exposeHost = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Nom de domaine à utiliser pour accéder à Gitea (via le reverse-proxy)";
    };

    exposeCert = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Nom du certificat à utiliser pour exposer Gitea (via le reverse-proxy)";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      services.gitea = {
        enable = true;
        stateDir = "/var/lib/gitea";

        settings = {
          server = {
            ROOT_URL = "https://${cfg.exposeHost}";
            HTTP_PORT = 3003;
            HTTP_ADDR = cfg.listenAddress;
          };

          metrics = {
            ENABLED = true;
          };
        };
      };

      profile.backup.paths = [ "/var/lib/gitea" ];

      # Ouverture du port pour Docker-Registry (via VPN uniquement)
      networking.firewall.interfaces.wg0.allowedTCPPorts = [
        3003
      ];
    })
    ({
      services.prometheus.scrapeConfigs = [
        {
          job_name = "gitea";
          scrape_interval = "15s";

          static_configs = [
            {
              targets = [ "${cfg.giteaHost}:3003" ];
            }
          ];
        }
      ];
    })
    (lib.mkIf cfg.expose {
      services.nginx.upstreams.gitea.servers = {
        "${cfg.giteaHost}:3003" = { };
      };

      services.nginx.virtualHosts."gitea" = {
        serverName = cfg.exposeHost;

        profile.useHTTPS = true;
        profile.certName = cfg.exposeCert;

        extraConfig = ''
          error_log /var/log/nginx/gitea_error.log;
          access_log /var/log/nginx/gitea_access.log;
        '';

        profile.blockMetrics = true;

        locations."/" = {
          proxyPass = "http://gitea";
        };
      };
    })
  ];
}
