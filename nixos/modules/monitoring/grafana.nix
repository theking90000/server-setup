# -------------------------------------------------------------------------
# grafana.nix — Dashboard Grafana pour la visualisation des métriques
#
# Déploie Grafana écoutant sur l'IP VPN (port 3000), configuré avec
# les datasources Prometheus auto-découvertes via le tag `prometheus`.
#
# Les dashboards sont déclarés dynamiquement par chaque module via
# l'option `infra.grafana.dashboards` (liste de chemins vers des JSON).
# Tous les dashboards sont regroupés via pkgs.linkFarm dans un seul
# répertoire provisionné dans Grafana.
#
# Tags requis : `grafana`
# Secrets     : `infra.grafana.{password, grafana_secret}` (Colmena)
# -------------------------------------------------------------------------
{
  config,
  pkgs,
  lib,
  services,
  ops,
  ...
}:

let
  enabled = services.hasTag "grafana";

  dashboardsDir = pkgs.linkFarm "grafana-dashboards" (
    lib.imap0 (i: path: {
      name = "d${builtins.toString i}-${builtins.baseNameOf path}";
      path = path;
    }) config.infra.grafana.dashboards
  );
in
{
  options.infra.grafana = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique d'accès à Grafana (ex: https://grafana.example.com).";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Nom d'utilisateur administrateur Grafana.";
    };

    password = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Mot de passe administrateur Grafana (secret, déployé via Colmena).";
    };

    grafana_secret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Clé secrète Grafana pour le chiffrement des sessions (secret, déployé via Colmena).";
    };

    dashboards = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Liste de chemins vers des fichiers JSON de dashboards Grafana.
        Chaque module peut déclarer ses propres dashboards via cette option.
        Les fichiers sont regroupés par linkFarm et provisionnés dans Grafana.
      '';
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ "grafana" ]; }
    (lib.mkIf enabled {
      deployment.keys = ops.mkSecretKeys "grafana" config.infra.grafana [
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

            root_url = config.infra.grafana.url;
          };

          security = {
            admin_password = "$__file{/run/credentials/grafana.service/admin_pwd}";
            admin_user = config.infra.grafana.user;
            secret_key = "$__file{/run/credentials/grafana.service/grafana_secret}";
          };
        };

        provision.enable = true;

        provision.dashboards.settings.providers = [
          {
            name = "Infrastructure";
            options.path = dashboardsDir;
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
    (lib.mkIf (config.infra.grafana.url != null) {
      infra.security.acls = [
        {
          port = 3000;
          allowedTags = [ "web-server" ];
          description = "Grafana Web Interface";
        }
      ];

      infra.ingress."grafana" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] config.infra.grafana.url;
        backend = map (ip: "${ip}:3000") (services.getVpnIpsByTag "grafana");
      };
    })
  ];
}
