{
  config,
  lib,
  services,
  ...
}:

let
  enabled = services.hasTag "prometheus";
in
{
  options.infra.telemetry = lib.mkOption {
    default = { };
    type = lib.types.attrsOf (
      lib.types.listOf (
        lib.types.submodule {
          options = {
            targets = lib.mkOption {
              type = lib.types.listOf lib.types.str;
            };
            labels = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
            };
          };
        }
      )
    );
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ "prometheus" ]; }
    (lib.mkIf enabled {
      services.prometheus = {
        enable = true;
        port = 9090;
        listenAddress = services.getVpnIp;

        retentionTime = "15d";

        scrapeConfigs = lib.mapAttrsToList (jobName: content: {
          job_name = jobName;
          scrape_interval = "15s";
          static_configs = content;
          relabel_configs = [
            {
              source_labels = [ "__address__" ];
              regex = "(.+):9100";
              target_label = "instance";
              replacement = "$1";
            }
            {
              source_labels = [ "__name__" ];
              regex = "^(go_|process_).*";
              action = "drop";
            }
          ];

          # We don't rely on auth as authentification, but rather on IP control.
          basic_auth = {
            username = "user";
            password = "password";
          };

        }) config.infra.telemetry;
      };

      infra.security.acls = [
        {
          port = 9090;
          allowedTags = [ "grafana" ];
          description = "Prometheus Metrics";
        }
      ];
    })
    ({
      # Informer Grafana de la source de données
      services.grafana.provision.datasources.settings.datasources = builtins.map (host: {
        name = "Prometheus ${host}";
        type = "prometheus";
        url = "http://${host}:9090";
      }) (services.getHostsByTag "prometheus");
    })
  ];
}
