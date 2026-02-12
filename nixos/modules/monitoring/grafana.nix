{
  config,
  lib,
  services,
  ops,
  ...
}:

let
  enabled = services.hasTag "grafana";
  cfg = (import ../../../config/grafana/grafana.nix);
in
{

  config = lib.mkMerge [
    (lib.mkIf enabled {
      deployment.keys = ops.mkSecretKeys "grafana" cfg [ "password" ];

      systemd.services.grafana.serviceConfig = {
        LoadCredential = [
          "admin_pwd:/var/lib/secrets/grafana/password"
        ];
      };

      services.grafana = {
        enable = true;
        settings = {
          server = {
            http_port = 3000;
            http_addr = services.getVpnIp;

            root_url = cfg.url;
          };

          security = {
            admin_password = "$__file{/run/credentials/grafana.service/admin_pwd}";
            admin_user = cfg.user;
          };
        };

        provision.enable = true;

        provision.dashboards.settings.providers = [
          {
            name = "Infrastructure";
            options.path = ../../../config/grafana/dashboards;
            recursive = true;
            checksum = true;
            options.foldersFromFilesStructure = true;
          }
        ];
      };

      # On ajoute le dossier Grafana aux backups
      # profile.backup.paths = [ "/var/lib/grafana" ];

      infra.security.acls = [
        {
          port = 3000;
          allowedTags = [ "webserver" ];
          description = "Grafana Web Interface";
        }
      ];
    })
    (lib.mkIf (cfg.url != null) {
      infra.ingress."grafana" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] cfg.url;
        backend = map (ip: "${ip}:3000") (services.getVpnIpsByTag "grafana");
      };
    })
  ];
}
