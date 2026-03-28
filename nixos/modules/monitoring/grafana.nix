{
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
      deployment.keys = ops.mkSecretKeys "grafana" cfg [
        "password"
        "grafana_secret"
      ];

      systemd.services.grafana.serviceConfig = {
        LoadCredential = [
          "admin_pwd:/var/lib/secrets/grafana/password"
          "grafana_secret:/var/lib/secrets/grafana/grafana_secret"
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
            secret_key = "$__file{/run/credentials/grafana.service/grafana_secret}";
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

        provision.datasources.settings.datasources = map (ip: {
          name = "Prometheus";
          type = "prometheus";

          url = "http://${ip}:9090";
        }) (services.getVpnIpsByTag "prometheus");
      };

      infra.backup.paths = [ "/var/lib/grafana/data" ];

    })
    (lib.mkIf (cfg.url != null) {
      infra.security.acls = [
        {
          port = 3000;
          allowedTags = [ "web-server" ];
          description = "Grafana Web Interface";
        }
      ];

      infra.ingress."grafana" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] cfg.url;
        backend = map (ip: "${ip}:3000") (services.getVpnIpsByTag "grafana");
      };
    })
  ];
}
