# -------------------------------------------------------------------------
# synapse.nix — Serveur Matrix Synapse
#
# Déploie un homeserver Synapse avec PostgreSQL local, fédération derrière
# l'ingress Nginx, métriques Prometheus et authentification OIDC Kanidm quand
# un nœud `kanidm` existe. Le module conserve les secrets hors du Nix store et
# prépare un dump PostgreSQL cohérent avant les sauvegardes Restic.
#
# Tag requis : `applications/synapse`
# Secrets    : SOPS colocalisé dans secrets/synapse.json
# -------------------------------------------------------------------------
{
  config,
  lib,
  pkgs,
  services,
  ...
}:

let
  cfg = config.infra.synapse;
  tag = "applications/synapse";
  enabled = services.hasTag tag;
  synapseHosts = services.getHostsByTag tag;
  synapseIps = services.getVpnIpsByTag tag;
  synapseAvailable = synapseHosts != [ ];
  kanidmAvailable = services.getHostsByTag "kanidm" != [ ];
  ssoEnabled = synapseAvailable && kanidmAvailable && cfg.url != null;

  dataDir = "/var/lib/matrix-synapse";
  databaseName = "matrix-synapse";
  databaseDumpDir = "/var/lib/matrix-synapse-backup";
  secretConfigPath = "/run/matrix-synapse/secrets.json";
  registrationSecretFile = "/run/secrets/synapse/registration-shared-secret";
  ssoSecretFile = "/run/secrets/sso/synapse-client-secret";
  ssoCredentialFile = "/run/credentials/matrix-synapse.service/oidc_client_secret";
  ssoSecretRequiredHere = ssoEnabled && (enabled || services.hasTag "kanidm");

  publicBaseUrl = if cfg.url == null then null else "${lib.removeSuffix "/" cfg.url}/";
  publicHost =
    if cfg.url == null then
      null
    else
      let
        match = builtins.match "https://([^/:]+)/?" cfg.url;
      in
      if match == null then null else builtins.elemAt match 0;
  delegated =
    synapseAvailable
    && cfg.url != null
    && cfg.serverName != null
    && publicHost != null
    && cfg.serverName != publicHost;

  serverWellKnown = builtins.toJSON { "m.server" = "${publicHost}:443"; };
  clientWellKnown = builtins.toJSON {
    "m.homeserver" = {
      base_url = lib.removeSuffix "/" cfg.url;
    };
  };
in
{
  options.infra.synapse = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL HTTPS publique de Synapse, sans chemin ni port (ex: https://matrix.example.com).";
    };

    serverName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Domaine immuable des identifiants Matrix (ex: example.com).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8008;
      description = "Port HTTP Matrix écouté sur l'adresse WireGuard.";
    };

    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 9000;
      description = "Port interne des métriques Prometheus Synapse.";
    };

    maxUploadSize = lib.mkOption {
      type = lib.types.str;
      default = "100M";
      description = "Taille maximale d'un upload Matrix.";
    };

    passwordLoginEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Conserver la connexion locale par mot de passe quand le SSO Kanidm est actif.";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }

    (lib.mkIf enabled {
      sops.secrets."synapse/registration-shared-secret" = {
        sopsFile = config.infra.sops.secretsDirectory + "/synapse.json";
        key = "registration_shared_secret";
        mode = "0400";
      };
    })

    (lib.mkIf ssoSecretRequiredHere {
      sops.secrets."sso/synapse-client-secret" = {
        sopsFile = config.infra.sops.secretsDirectory + "/synapse.json";
        key = "oidc_client_secret";
        owner = if services.hasTag "kanidm" then "kanidm" else "root";
        mode = "0400";
      };
    })

    (lib.mkIf enabled {
      assertions = [
        {
          assertion = cfg.url != null;
          message = "infra.synapse.url is required on nodes tagged applications/synapse.";
        }
        {
          assertion = cfg.serverName != null;
          message = "infra.synapse.serverName is required on nodes tagged applications/synapse.";
        }
        {
          assertion = builtins.length synapseHosts == 1;
          message = "Exactly one node may use applications/synapse; this module does not configure shared Synapse workers.";
        }
        {
          assertion = services.getHostsByTag "web-server" != [ ];
          message = "A web-server node is required to expose the Synapse client and federation APIs on HTTPS port 443.";
        }
        {
          assertion = cfg.url == null || publicHost != null;
          message = "infra.synapse.url must be an HTTPS origin without a path or explicit port.";
        }
        {
          assertion = cfg.serverName == null || builtins.match "[A-Za-z0-9.-]+" cfg.serverName != null;
          message = "infra.synapse.serverName must be a domain name without scheme, path, or port.";
        }
        {
          assertion = cfg.port != cfg.metricsPort;
          message = "infra.synapse.port and infra.synapse.metricsPort must be different.";
        }
      ];

      services.postgresql = {
        enable = true;
        ensureUsers = [
          {
            name = databaseName;
            ensureClauses.login = true;
          }
        ];
      };

      # `ensureDatabases` inherits the cluster locale. Synapse requires a
      # database created explicitly from template0 with C collation.
      systemd.services.postgresql-setup.script = lib.mkAfter ''
        if ! ${config.services.postgresql.package}/bin/psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${databaseName}'" | ${pkgs.gnugrep}/bin/grep -q 1; then
          ${config.services.postgresql.package}/bin/createdb \
            --encoding=UTF8 \
            --locale=C \
            --template=template0 \
            --owner=${databaseName} \
            ${databaseName}
        fi

        if ! ${config.services.postgresql.package}/bin/psql -tAc "SELECT datcollate = 'C' AND datctype = 'C' FROM pg_database WHERE datname = '${databaseName}'" | ${pkgs.gnugrep}/bin/grep -qx t; then
          echo "The ${databaseName} database must use C collation and ctype." >&2
          exit 1
        fi
      '';

      services.matrix-synapse = {
        enable = true;
        enableRegistrationScript = true;
        inherit dataDir;
        extraConfigFiles = [ secretConfigPath ];

        settings = {
          server_name = cfg.serverName;
          public_baseurl = publicBaseUrl;
          report_stats = false;
          enable_registration = false;
          enable_registration_without_verification = false;
          allow_guest_access = false;
          enable_metrics = true;
          max_upload_size = cfg.maxUploadSize;
          url_preview_enabled = false;
          serve_server_wellknown = !delegated;

          password_config.localdb_enabled = !ssoEnabled || cfg.passwordLoginEnabled;

          database = {
            name = "psycopg2";
            args = {
              database = databaseName;
              user = databaseName;
            };
          };

          listeners = [
            {
              port = cfg.port;
              bind_addresses = [ services.getVpnIp ];
              type = "http";
              tls = false;
              x_forwarded = true;
              resources = [
                {
                  names = [ "client" ];
                  compress = true;
                }
                {
                  names = [ "federation" ];
                  compress = false;
                }
              ];
            }
            {
              port = cfg.metricsPort;
              bind_addresses = [ services.getVpnIp ];
              type = "metrics";
              tls = false;
              resources = [ ];
            }
          ];
        }
        // lib.optionalAttrs ssoEnabled {
          oidc_providers = [
            {
              idp_id = "kanidm";
              idp_name = "Kanidm";
              discover = true;
              issuer = "${lib.removeSuffix "/" config.infra.kanidm.url}/oauth2/openid/synapse/";
              client_id = "synapse";
              client_secret_path = ssoCredentialFile;
              client_auth_method = "client_secret_basic";
              pkce_method = "always";
              scopes = [
                "openid"
                "profile"
                "email"
              ];
              allow_existing_users = true;
              user_mapping_provider.config.localpart_template = "{{ user.preferred_username }}";
            }
          ];
        };
      };

      systemd.services.matrix-synapse = {
        serviceConfig.LoadCredential = [
          "registration_shared_secret:${registrationSecretFile}"
        ]
        ++ lib.optional ssoEnabled "oidc_client_secret:${ssoSecretFile}";

        # JSON est un sous-ensemble de YAML. Le secret d'enregistrement est
        # ainsi encodé correctement sans jamais être copié dans le Nix store.
        preStart = lib.mkBefore ''
          ${pkgs.jq}/bin/jq -n \
            --rawfile registration_shared_secret "$CREDENTIALS_DIRECTORY/registration_shared_secret" \
            '{registration_shared_secret: ($registration_shared_secret | rtrimstr("\n"))}' \
            > ${secretConfigPath}
        '';
      };

      infra.security.acls = [
        {
          port = cfg.port;
          allowedTags = [ "web-server" ];
          description = "Synapse Matrix client and federation API";
        }
        {
          port = cfg.metricsPort;
          allowedTags = [ "prometheus" ];
          description = "Synapse Prometheus metrics";
        }
      ];

      infra.backup = {
        paths = [
          dataDir
          databaseDumpDir
        ];
        prepareCommands = [
          ''
            install -d -m 0700 -o matrix-synapse -g matrix-synapse ${databaseDumpDir}
            dump=${databaseDumpDir}/database.dump
            tmp="$dump.tmp"
            rm -f "$tmp"
            trap 'rm -f "$tmp"' EXIT
            ${pkgs.util-linux}/bin/runuser -u matrix-synapse -- \
              ${config.services.postgresql.package}/bin/pg_dump \
              --format=custom \
              --exclude-table-data=e2e_one_time_keys_json \
              --file="$tmp" \
              ${databaseName}
            mv "$tmp" "$dump"
            chmod 0600 "$dump"
            trap - EXIT
          ''
        ];
      };
    })

    {
      infra.telemetry.synapse = map (host: {
        targets = [ "${host}:${toString cfg.metricsPort}" ];
        labels = { inherit host; };
        metrics_path = "/_synapse/metrics";
      }) synapseHosts;
    }

    (lib.mkIf (synapseIps != [ ] && cfg.url != null) {
      infra.ingress.synapse = {
        url = cfg.url;
        proxyTo = map (ip: "http://${ip}:${toString cfg.port}") synapseIps;
        routes.admin = {
          path = "/_synapse/admin";
          nginx.return = "403";
        };
        routes.main.nginx.extraConfig = ''
          proxy_read_timeout 600s;
          proxy_send_timeout 600s;
        '';
        nginx.extraConfig = "client_max_body_size ${cfg.maxUploadSize};";
      };
    })

    (lib.mkIf ssoEnabled {
      infra.sso.synapse = {
        displayName = "Matrix";
        serviceTag = tag;
        redirectUris = [ "${publicBaseUrl}_synapse/client/oidc/callback" ];
        landingUrl = cfg.url;
        secretFile = ssoSecretFile;
        scopes = [
          "openid"
          "profile"
          "email"
        ];
        groups.users = { };
      };
    })

    # Lorsque les MXID utilisent le domaine racine mais que Synapse est servi
    # sur un sous-domaine, l'ingress publie les deux délégations Matrix sur
    # 443. L'entrée se fusionne avec les autres routes du domaine racine
    # (ex: un site www sur l'apex) dans un même vhost et un même certificat.
    (lib.mkIf delegated {
      infra.ingress.synapse-wellknown = {
        endpoint.host = cfg.serverName;

        routes.server = {
          path = "/.well-known/matrix/server";
          match = "exact";
          nginx = {
            return = "200 '${serverWellKnown}'";
            extraConfig = "default_type application/json;";
          };
        };

        routes.client = {
          path = "/.well-known/matrix/client";
          match = "exact";
          nginx = {
            return = "200 '${clientWellKnown}'";
            extraConfig = ''
              default_type application/json;
              add_header Access-Control-Allow-Origin "*" always;
            '';
          };
        };
      };
    })
  ];
}
