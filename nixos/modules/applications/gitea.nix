# -------------------------------------------------------------------------
# gitea.nix — Serveur Git auto-hébergé
#
# Déploie Gitea écoutant sur l'IP VPN (port 3003) avec métriques
# Prometheus activées. Si une URL publique est configurée, déclare
# automatiquement les ACLs, l'ingress Nginx et la télémétrie.
#
# Tags requis : `applications/gitea`
# -------------------------------------------------------------------------
{
  config,
  pkgs,
  services,
  lib,
  ...
}:

let
  cfg = config.infra.gitea;
  tag = "applications/gitea";
  enabled = services.hasTag tag;
  port = 3003;
  dataDir = "/var/lib/gitea";
  kanidmAvailable = services.getHostsByTag "kanidm" != [ ];
  giteaAvailable = services.getHostsByTag tag != [ ];
  ssoEnabled = kanidmAvailable && giteaAvailable && cfg.url != null;
  ssoSecretFile = "/run/secrets/sso/gitea-client-secret";
  giteaExe = lib.getExe config.services.gitea.package;
in
{
  # Public API
  options.infra.gitea = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique de l'instance Gitea (ex: https://git.example.com).";
    };

    registrationEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Autoriser l'inscription libre des utilisateurs.";
    };
  };

  config = lib.mkMerge [
    # Module contract
    { infra.registeredTags = [ tag ]; }

    # Local configuration
    (lib.mkIf enabled {
      services.gitea = {
        enable = true;
        stateDir = dataDir;

        settings = {
          server = {
            HTTP_PORT = port;
            HTTP_ADDR = services.getVpnIp;
          }
          // lib.optionalAttrs (cfg.url != null) {
            ROOT_URL = cfg.url;
          };

          metrics = {
            ENABLED = true;
          };

          service = {
            DISABLE_REGISTRATION = !cfg.registrationEnabled;
          };
        };
      };

      services.gitea.settings.oauth2_client = lib.mkIf ssoEnabled {
        ENABLE_AUTO_REGISTRATION = true;
        USERNAME = "preferred_username";
        OPENID_CONNECT_SCOPES = "openid profile email";
        ACCOUNT_LINKING = "login";
      };

      infra.backup.paths = [ dataDir ];

      infra.security.acls = [
        {
          port = port;
          allowedTags = [
            "web-server"
            "prometheus"
          ];
          description = "Gitea";
        }
      ];

    })

    # Gitea stores OAuth sources in its database, so reconcile the source after
    # the NixOS module migrations and before the web process loads it.
    (lib.mkIf (enabled && ssoEnabled) {
      systemd.services.gitea = {
        after = lib.optional (services.hasTag "kanidm") "kanidm.service";
        serviceConfig.LoadCredential = [ "oidc_client_secret:${ssoSecretFile}" ];
        preStart = lib.mkAfter ''
          oidc_source_ids="$(${giteaExe} admin auth list --vertical-bars --padding 0 --pad-char ' ' | ${pkgs.gawk}/bin/awk -F '|' '$2 == "kanidm" { print $1 }')"

          if [[ "$oidc_source_ids" == *$'\n'* ]]; then
            echo "Multiple Gitea authentication sources named kanidm" >&2
            exit 1
          fi

          oidc_secret="$(< "$CREDENTIALS_DIRECTORY/oidc_client_secret")"
          oidc_args=(
            --name kanidm
            --provider openidConnect
            --key gitea
            --secret "$oidc_secret"
            --auto-discover-url "${config.infra.kanidm.url}/oauth2/openid/gitea/.well-known/openid-configuration"
          )

          if [ -z "$oidc_source_ids" ]; then
            ${giteaExe} admin auth add-oauth "''${oidc_args[@]}"
          else
            ${giteaExe} admin auth update-oauth --id "$oidc_source_ids" "''${oidc_args[@]}"
          fi
        '';
      };
    })

    # Fleet-wide contributions
    {
      infra.telemetry."gitea" = map (host: {
        targets = [ "${host}:${toString port}" ];
        labels = { inherit host; };
      }) (services.getHostsByTag tag);
    }
    (lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."gitea" = {
        url = cfg.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);
        blockPaths = [ "/metrics" ];
      };
    })
    (lib.mkIf (services.getHostsByTag tag != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/gitea.json ];
    })
    (lib.mkIf ssoEnabled {
      infra.sso.gitea = {
        displayName = "Gitea";
        serviceTag = tag;
        redirectUris = [ "${cfg.url}/user/oauth2/kanidm/callback" ];
        landingUrl = cfg.url;
        secretFile = ssoSecretFile;
        pkce = false;
        groups.users = { };
      };
    })
  ];
}
