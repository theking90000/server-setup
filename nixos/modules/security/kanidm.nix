# -------------------------------------------------------------------------
# kanidm.nix — Kanidm identity provider (SSO / OIDC / OAuth2 / LDAPS)
#
# Déploie Kanidm écoutant en HTTPS sur l'IP VPN. Le domaine public est
# géré via infra.ingress (reverse proxy Nginx HTTPS → HTTPS avec
# backendTls). Les certificats ACME sont chargés via LoadCredential
# systemd — pas de service intermédiaire.
#
# Options exposées pour les autres modules :
#   - infra.kanidm.url         : URL publique (ex: https://idm.example.com)
#   - infra.kanidm.users       : provisioning déclaratif d'utilisateurs
#   - infra.kanidm.oauth2      : enregistrement des clients OAuth2/OIDC
#   - infra.kanidm.groups      : provisioning de groupes Kanidm
#
# Tags requis : `kanidm`
#
# Secrets     : infra.kanidm.users.<name>.password (déployé via Colmena,
#               pas auto-setté dans kanidm)
# -------------------------------------------------------------------------
{
  config,
  lib,
  pkgs,
  services,
  ops,
  ...
}:

let
  tag = "kanidm";
  enabled = services.hasTag tag;
  cfg = config.infra.kanidm;

  # ── URL parsing ───────────────────────────────────────────────────────
  # "https://idm.example.com/auth" → domain = "idm.example.com"
  parseDomain =
    url:
    let
      m = builtins.match "https?://([^/]+)(/.*)?" url;
    in
    if m != null then builtins.elemAt m 0 else null;

  domain = if cfg.url != null then parseDomain cfg.url else null;

  certName = lib.replaceStrings [ "*" ] [ "_" ] domain;

  kanidmIps = services.getVpnIpsByTag tag;

  ldapsConfig = cfg.ldapPort != null;

  # ── OAuth2 clients → kanidm provision ──
  oidcConfig = lib.mapAttrsToList (name: client: {
    inherit name;
    displayName = client.displayName;
    originUrl = client.redirectUris;
    scopeMaps = client.scopeMaps;
    supplementaryScopeMaps = client.supplementaryScopeMaps;
    claimMaps = client.claimMaps;
  }) cfg.oauth2;

in
{
  options.infra.kanidm = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique Kanidm (ex: https://idm.example.com).";
    };

    port = lib.mkOption {
      type = lib.types.int;
      default = 8443;
      description = "Port HTTPS d'écoute sur l'IP VPN.";
    };

    ldapPort = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Port LDAPS (null = désactivé).";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            displayName = lib.mkOption {
              type = lib.types.str;
              description = "Nom affiché.";
            };
            isAdmin = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Ajouter au groupe idm_admin.";
            };
            email = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Adresse email.";
            };
            password = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Mot de passe (secret — déployé via Colmena, pas auto-setté dans Kanidm).";
            };
          };
        }
      );
      default = { };
      description = "Utilisateurs Kanidm provisionnés.";
    };

    oauth2 = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            displayName = lib.mkOption {
              type = lib.types.str;
              description = "Nom affiché du client OAuth2.";
            };
            redirectUris = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "URIs de redirection autorisées.";
            };
            scopeMaps = lib.mkOption {
              type = lib.types.attrsOf (lib.types.listOf lib.types.str);
              default = { };
              description = "Maps groupes Kanidm → scopes OAuth.";
            };
            supplementaryScopeMaps = lib.mkOption {
              type = lib.types.attrsOf (lib.types.listOf lib.types.str);
              default = { };
              description = "Maps groupes Kanidm → scopes supplémentaires.";
            };
            claimMaps = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    valuesByGroup = lib.mkOption {
                      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
                      default = { };
                      description = "Maps groupes Kanidm → valeurs du claim.";
                    };
                  };
                }
              );
              default = { };
              description = "Claims additionnels par groupe.";
            };
          };
        }
      );
      default = { };
      description = "Clients OAuth2/OIDC enregistrés.";
    };

    groups = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            members = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Membres du groupe (personnes ou groupes).";
            };
          };
        }
      );
      default = { };
      description = "Groupes Kanidm provisionnés.";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }

    # ── Kanidm server (per-node, URL required) ──
    (lib.mkIf (enabled && cfg.url != null) {
      services.kanidm.enableServer = true;

      services.kanidm.serverSettings = {
        bindaddress = "${services.getVpnIp}:${toString cfg.port}";
        origin = cfg.url;
        domain = domain;
        tls_chain = "/run/credentials/kanidm.service/tls_chain";
        tls_key = "/run/credentials/kanidm.service/tls_key";
      };

      infra.acme.domains = [
        {
          domain = domain;
          services = [ "kanidm" ];
        }
      ];

      services.kanidm.serverSettings.online_backup = {
        path = "/var/lib/kanidm/backups";
        schedule = "00 22 * * *";
      };

      # ── Load ACME certs via systemd credentials ──
      systemd.services.kanidm.serviceConfig.LoadCredential = [
        "tls_chain:/var/lib/acme/${certName}/fullchain.pem"
        "tls_key:/var/lib/acme/${certName}/key.pem"
      ];

      # ── Secrets : user passwords ──
      deployment.keys = lib.mkMerge (
        lib.mapAttrsToList (
          name: user:
          lib.mkIf (user.password != null) (
            ops.mkSecretKeys "kanidm/users/${name}" { password = user.password; } [ "password" ]
          )
        ) cfg.users
      );

      # ── ACLs ──
      infra.security.acls = [
        {
          port = cfg.port;
          allowedTags = [
            "web-server"
            "prometheus"
          ];
          description = "Kanidm HTTPS";
        }
      ];

      # ── Backup ──
      infra.backup.paths = [
        "/var/lib/kanidm"
      ];
    })

    # ── LDAPS bind address (per-node, optional) ──
    (lib.mkIf (enabled && cfg.url != null && ldapsConfig) {
      services.kanidm.serverSettings.ldapbindaddress = "${services.getVpnIp}:${toString cfg.ldapPort}";
    })

    # ── User provisioning → kanidm persons ──
    (lib.mkIf (enabled && cfg.users != { }) {
      services.kanidm.provision.persons = lib.mapAttrs (
        _: user:
        {
          displayName = user.displayName;
        }
        // lib.optionalAttrs (user.email != null) { mailAddresses = [ user.email ]; }
        // lib.optionalAttrs user.isAdmin { groups = [ "idm_admin" ]; }
      ) cfg.users;
    })

    # ── Group provisioning ──
    (lib.mkIf (enabled && cfg.groups != { }) {
      services.kanidm.provision.groups = cfg.groups;
    })

    # ── OAuth2 client provisioning ──
    (lib.mkIf (enabled && cfg.oauth2 != { }) {
      services.kanidm.provision.systems.oauth2 = lib.listToAttrs (
        map (client: {
          name = client.name;
          value = {
            displayName = client.displayName;
            originUrl = client.originUrl;
            scopeMaps = client.scopeMaps;
            supplementaryScopeMaps = client.supplementaryScopeMaps;
            claimMaps = client.claimMaps;
          };
        }) oidcConfig
      );
    })

    # ── Ingress (global, guarded by URL + backends) ──
    (lib.mkIf (cfg.url != null && kanidmIps != [ ]) {
      infra.ingress."kanidm" = {
        url = cfg.url;
        backend = map (ip: "${ip}:${toString cfg.port}") kanidmIps;
        backendTls = true;
        blockPaths = [ "/metrics" ];
      };
    })

    # ── Telemetry (global) ──
    {
      infra.telemetry."kanidm" = map (host: {
        targets = [ "${host}:${toString cfg.port}" ];
        labels = {
          host = host;
          job = "kanidm";
        };
      }) (services.getHostsByTag tag);
    }

  ];
}
