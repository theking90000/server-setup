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
# Secrets     : `infra.grafana.{password, grafanaSecret}` (Colmena)
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
  cfg = config.infra.grafana;
  tag = "grafana";
  enabled = services.hasTag tag;
  port = 3000;
  dataDir = "/var/lib/grafana/data";
  kanidmAvailable = services.getHostsByTag "kanidm" != [ ];
  grafanaAvailable = services.getHostsByTag tag != [ ];
  ssoEnabled = kanidmAvailable && grafanaAvailable && cfg.url != null;
  ssoSecretFile = "/run/secrets/sso/grafana-client-secret";

  passwordPath =
    if cfg.passwordFile != null then cfg.passwordFile else "/var/lib/secrets/grafana/password";
  secretPath =
    if cfg.grafanaSecretFile != null then
      cfg.grafanaSecretFile
    else
      "/var/lib/secrets/grafana/grafana_secret";

  dashboardsDir = pkgs.linkFarm "grafana-dashboards" (
    lib.imap0 (i: path: {
      name = "d${builtins.toString i}-${builtins.baseNameOf path}";
      path = path;
    }) cfg.dashboards
  );
in
{
  imports = [
    (lib.mkRenamedOptionModule
      [ "infra" "grafana" "grafana_secret" ]
      [ "infra" "grafana" "grafanaSecret" ]
    )
  ];

  # Public API
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

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Chemin runtime du mot de passe administrateur Grafana.";
    };

    grafanaSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Clé secrète Grafana pour le chiffrement des sessions (secret, déployé via Colmena).";
    };

    grafanaSecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Chemin runtime de la clé secrète Grafana.";
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
    # Module contract
    { infra.registeredTags = [ tag ]; }

    # Local configuration
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = (cfg.password != null) != (cfg.passwordFile != null);
          message = "Set exactly one of infra.grafana.password or infra.grafana.passwordFile on nodes tagged grafana.";
        }
        {
          assertion = (cfg.grafanaSecret != null) != (cfg.grafanaSecretFile != null);
          message = "Set exactly one of infra.grafana.grafanaSecret or infra.grafana.grafanaSecretFile on nodes tagged grafana.";
        }
        {
          assertion = !kanidmAvailable || cfg.url != null;
          message = "infra.grafana.url is required when a node tagged kanidm enables automatic Grafana SSO.";
        }
      ];

      deployment.keys =
        ops.mkSecretKeys "grafana"
          {
            password = if cfg.passwordFile == null then cfg.password else null;
            grafana_secret = if cfg.grafanaSecretFile == null then cfg.grafanaSecret else null;
          }
          [
            "password"
            "grafana_secret"
          ];

      systemd.services.grafana.serviceConfig = {
        LoadCredential = [
          "admin_pwd:${passwordPath}"
          "grafana_secret:${secretPath}"
        ]
        ++ lib.optional ssoEnabled "oidc_client_secret:${ssoSecretFile}";
      };

      services.grafana = {
        enable = true;
        settings = {
          server = {
            http_port = port;
            http_addr = services.getVpnIp;
          }
          // lib.optionalAttrs (cfg.url != null) {
            root_url = cfg.url;
          };

          security = {
            admin_password = "$__file{/run/credentials/grafana.service/admin_pwd}";
            admin_user = cfg.user;
            secret_key = "$__file{/run/credentials/grafana.service/grafana_secret}";
          };
        }
        // lib.optionalAttrs ssoEnabled {
          auth.disable_login_form = true;

          "auth.basic".enabled = false;

          "auth.generic_oauth" = {
            enabled = true;
            name = "Kanidm";
            auto_login = true;
            client_id = "grafana";
            client_secret = "$__file{/run/credentials/grafana.service/oidc_client_secret}";
            auth_style = "InHeader";
            scopes = "openid profile email groups";
            auth_url = "${config.infra.kanidm.url}/ui/oauth2";
            token_url = "${config.infra.kanidm.url}/oauth2/token";
            api_url = "${config.infra.kanidm.url}/oauth2/openid/grafana/userinfo";
            use_pkce = true;
            use_refresh_token = true;
            allow_sign_up = true;
            login_attribute_path = "preferred_username";
            groups_attribute_path = "groups";
            role_attribute_path = "contains(grafana_role[*], 'Admin') && 'Admin' || contains(grafana_role[*], 'Editor') && 'Editor' || contains(grafana_role[*], 'Viewer') && 'Viewer'";
            role_attribute_strict = true;
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

        provision.datasources.settings.datasources = map (host: {
          name = "Prometheus ${host}";
          type = "prometheus";
          url = "http://${host}:9090";
        }) (services.getHostsByTag "prometheus");
      };

      infra.backup.paths = [ dataDir ];

      infra.security.acls = lib.optional (cfg.url != null) {
        inherit port;
        allowedTags = [ "web-server" ];
        description = "Grafana Web Interface";
      };
    })

    # Fleet-wide contributions
    (lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."grafana" = {
        url = cfg.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);
      };
    })

    # Automatic SSO registration (fleet-wide)
    (lib.mkIf ssoEnabled {
      infra.sso.grafana = {
        displayName = "Grafana";
        serviceTag = tag;
        redirectUris = [ "${cfg.url}/login/generic_oauth" ];
        landingUrl = cfg.url;
        secretFile = ssoSecretFile;
        scopes = [
          "openid"
          "profile"
          "email"
          "groups"
        ];
        groups = {
          viewers.claims.grafana_role = [ "Viewer" ];
          editors.claims.grafana_role = [ "Editor" ];
          admins.claims.grafana_role = [ "Admin" ];
        };
      };
    })
  ];
}
