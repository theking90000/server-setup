{
  config,
  lib,
  services,
  ...
}:

let
  cfg = config.infra.telemetry;
  tag = "prometheus";
  enabled = services.hasTag tag;
  port = 9090;

  mkScrapeConfig =
    jobName: targets:
    let
      primary = if targets == [ ] then null else lib.head targets;
    in
    {
      job_name = jobName;
      scrape_interval = "15s";
      static_configs = map (target: { inherit (target) targets labels; }) targets;
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
    // lib.optionalAttrs (primary != null) {
      inherit (primary) scheme;
    }
    // lib.optionalAttrs (primary != null && primary.tls_config != null) {
      inherit (primary) tls_config;
    }
    // lib.optionalAttrs (primary != null && primary.basic_auth != null) {
      inherit (primary) basic_auth;
    };
in
{
  # Public API shared by service modules.
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
    # Module contract
    { infra.registeredTags = [ tag ]; }

    # Local configuration
    (lib.mkIf enabled {
      services.prometheus = {
        enable = true;
        inherit port;
        listenAddress = services.getVpnIp;

        retentionTime = "15d";

        scrapeConfigs = lib.mapAttrsToList mkScrapeConfig cfg;
      };

      infra.security.acls = [
        {
          inherit port;
          allowedTags = [ "grafana" ];
          description = "Prometheus Metrics";
        }
      ];
    })
  ];
}
