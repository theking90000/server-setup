# -------------------------------------------------------------------------
# docker-registry.nix — Registre Docker privé
#
# Déploie un registre Docker écoutant sur l'IP VPN (port 5000) avec
# authentification htpasswd. Exporte les métriques Prometheus sur le port
# 5001. Si une URL publique est configurée, déclare automatiquement
# les règles ACL + ingress Nginx + télémétrie Prometheus.
#
# Tags requis : `applications/docker-registry`
# Secrets     : SOPS colocalisé, avec options texte/*File pour compatibilité
# -------------------------------------------------------------------------
{
  config,
  services,
  lib,
  ops,
  ...
}:

let
  cfg = config.infra.dockerRegistry;
  tag = "applications/docker-registry";
  enabled = services.hasTag tag;
  servicePort = 5000;
  metricsPort = 5001;
  dataDir = "/var/lib/docker-registry";
  accountsPath =
    if cfg.accountsFile != null then
      cfg.accountsFile
    else if cfg.accounts != null then
      "/var/lib/secrets/docker-registry/accounts"
    else
      "/run/secrets/docker-registry/accounts";
  useSops = enabled && cfg.accounts == null && cfg.accountsFile == null;
in
{
  # Public API
  options.infra.dockerRegistry = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique du registre Docker (ex: https://registry.example.com).";
    };

    accounts = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Fichier htpasswd pour l'authentification du registre Docker.";
    };

    accountsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Chemin runtime du fichier htpasswd.";
    };
  };

  config = lib.mkMerge [
    # Module contract
    { infra.registeredTags = [ tag ]; }

    (lib.mkIf useSops {
      sops.secrets."docker-registry/accounts" = {
        sopsFile = config.infra.sops.secretsDirectory + "/docker-registry.json";
        key = "accounts";
      };
    })

    # Local configuration
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = cfg.accounts == null || cfg.accountsFile == null;
          message = "Set at most one of infra.dockerRegistry.accounts or infra.dockerRegistry.accountsFile on registry nodes.";
        }
      ];

      deployment.keys = ops.mkSecretKeys "docker-registry" {
        accounts = if cfg.accountsFile == null then cfg.accounts else null;
      } [ "accounts" ];

      systemd.services.docker-registry.serviceConfig = {
        LoadCredential = [
          "admin_pwd:${accountsPath}"
        ];
      };

      services.dockerRegistry = {
        enable = true;
        port = servicePort;
        listenAddress = services.getVpnIp;

        openFirewall = false;

        storagePath = dataDir;

        enableDelete = true;
        enableGarbageCollect = true;

        extraConfig = {
          auth = {
            htpasswd = {
              realm = "Registry";
              path = "/run/credentials/docker-registry.service/admin_pwd";
            };
          };

          http = {
            debug = {
              addr = "${services.getVpnIp}:${toString metricsPort}";
              prometheus = {
                enabled = true;
                path = "/metrics";
              };
            };
          };
        };
      };

      infra.backup.paths = [ dataDir ];

      infra.security.acls = [
        {
          port = servicePort;
          allowedTags = [ "web-server" ];
          description = "Docker registry";
        }
        {
          port = metricsPort;
          allowedTags = [ "prometheus" ];
          description = "Docker registry metrics";
        }
      ];

    })

    # Fleet-wide contributions
    {
      infra.telemetry."docker-registry" = map (host: {
        targets = [ "${host}:${toString metricsPort}" ];
        labels = { inherit host; };
      }) (services.getHostsByTag tag);
    }

    (lib.mkIf (services.getVpnIpsByTag tag != [ ] && cfg.url != null) {
      infra.ingress."docker-registry" = {
        url = cfg.url;
        proxyTo = map (ip: "http://${ip}:${toString servicePort}") (services.getVpnIpsByTag tag);
      };
    })
    (lib.mkIf (services.getHostsByTag tag != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/docker-registry.json ];
    })
  ];
}
