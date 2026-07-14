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
            scheme = lib.mkOption {
              type = lib.types.enum [
                "http"
                "https"
              ];
              default = "http";
              description = "Scheme pour le scrape (http ou https).";
            };
            tls_config = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    insecure_skip_verify = lib.mkOption {
                      type = lib.types.bool;
                      default = false;
                      description = "Désactiver la vérification TLS (ex: cert auto-signé, domain mismatch sur IP VPN).";
                    };
                  };
                }
              );
              default = null;
              description = "Configuration TLS pour les targets en HTTPS.";
            };
            basic_auth = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    username = lib.mkOption { type = lib.types.str; };
                    password = lib.mkOption { type = lib.types.str; };
                  };
                }
              );
              default = null;
              description = "Authentification HTTP Basic propre à ce job.";
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

        scrapeConfigs = lib.mapAttrsToList (
          jobName: content:
          {
            job_name = jobName;
            scrape_interval = "15s";
            static_configs = map (c: { inherit (c) targets labels; }) content;
            relabel_configs = [
              {
                source_labels = [ "__address__" ];
                regex = "(.+):9100";
                target_label = "instance";
                replacement = "$1";
              }
            ];
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = "^(go_|process_).*";
                action = "drop";
              }
            ];
          }
          // lib.optionalAttrs (content != [ ]) {
            scheme = (lib.head content).scheme;
          }
          // lib.optionalAttrs (content != [ ] && (lib.head content).tls_config != null) {
            tls_config = (lib.head content).tls_config;
          }
          // lib.optionalAttrs (content != [ ] && (lib.head content).basic_auth != null) {
            basic_auth = (lib.head content).basic_auth;
          }
        ) config.infra.telemetry;
      };

      infra.security.acls = [
        {
          port = 9090;
          allowedTags = [ "grafana" ];
          description = "Prometheus Metrics";
        }
      ];
    })
  ];
}
