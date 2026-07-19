# -------------------------------------------------------------------------
# kanidm.nix — Kanidm identity provider (SSO / OIDC / OAuth2 / LDAPS)
#
# Déploie Kanidm écoutant en HTTPS sur l'IP VPN. Le domaine public est
# géré via infra.ingress (reverse proxy Nginx HTTPS → backend HTTPS).
# Kanidm déclare son propre claim ACME (scope kanidm, certificat exact,
# clé distincte du wildcard nginx) et charge le certificat via
# LoadCredential systemd ; le renouvellement redémarre le service, car
# les credentials ne sont relus qu'au restart.
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
  sso = config.infra.sso;

  # ── URL parsing ───────────────────────────────────────────────────────
  # "https://idm.example.com/auth" → domain = "idm.example.com"
  parseDomain =
    url:
    let
      m = builtins.match "https?://([^/]+)(/.*)?" url;
    in
    if m != null then builtins.elemAt m 0 else null;

  domain = if cfg.url != null then parseDomain cfg.url else null;

  kanidmIps = services.getVpnIpsByTag tag;

  ldapsConfig = cfg.ldapPort != null;

  groupName =
    clientName: name: group:
    if group.kanidmName != null then group.kanidmName else "${clientName}_${name}";

  ssoGroups = lib.foldl' lib.recursiveUpdate { } (
    lib.mapAttrsToList (
      clientName: client:
      lib.mapAttrs' (
        name: group:
        lib.nameValuePair (groupName clientName name group) {
          members = [ ];
          overwriteMembers = false;
        }
      ) client.groups
    ) sso
  );

  claimMaps =
    clientName: client:
    let
      claimNames = lib.unique (
        lib.concatMap (group: lib.attrNames group.claims) (lib.attrValues client.groups)
      );
    in
    lib.genAttrs claimNames (claim: {
      joinType = "array";
      valuesByGroup = lib.mapAttrs' (
        name: group: lib.nameValuePair (groupName clientName name group) group.claims.${claim}
      ) (lib.filterAttrs (_: group: builtins.hasAttr claim group.claims) client.groups);
    });

  ssoOauth2 = lib.mapAttrs (clientName: client: {
    inherit (client)
      displayName
      public
      enableLegacyCrypto
      preferShortUsername
      ;
    originUrl = client.redirectUris;
    originLanding = client.landingUrl;
    basicSecretFile = if client.public then null else client.secretFile;
    allowInsecureClientDisablePkce = !client.pkce;
    scopeMaps = lib.mapAttrs' (
      name: group: lib.nameValuePair (groupName clientName name group) client.scopes
    ) client.groups;
    supplementaryScopeMaps = lib.mapAttrs' (
      name: group: lib.nameValuePair (groupName clientName name group) group.extraScopes
    ) (lib.filterAttrs (_: group: group.extraScopes != [ ]) client.groups);
    claimMaps = claimMaps clientName client;
  }) sso;

  hasProvisioning = cfg.users != { } || cfg.groups != { } || cfg.oauth2 != { } || sso != { };
  idmAdminPasswordFile = "/run/secrets/kanidm/idm-admin-password";
  useSopsIdmAdminPassword = enabled && sso != { };

  kanidmBasePackage =
    if pkgs ? kanidm_1_10 then
      pkgs.kanidm_1_10
    else if pkgs ? kanidm_1_9 then
      pkgs.kanidm_1_9
    else
      pkgs.kanidm_1_8;

  kanidmPackage = if sso == { } then kanidmBasePackage else kanidmBasePackage.withSecretProvisioning;

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

    (lib.mkIf useSopsIdmAdminPassword {
      sops.secrets."kanidm/idm-admin-password" = {
        sopsFile = config.infra.sops.secretsDirectory + "/kanidm.json";
        key = "idm_admin_password";
        owner = "kanidm";
        mode = "0400";
      };
    })

    (lib.mkIf enabled {
      assertions = [
        {
          assertion = cfg.url != null;
          message = "infra.kanidm.url is required on nodes tagged kanidm.";
        }
      ];
    })

    # ── Kanidm server (per-node, URL required) ──
    (lib.mkIf (enabled && cfg.url != null) {
      services.kanidm.server.enable = true;

      environment.systemPackages = [
        kanidmPackage
      ];

      services.kanidm.package = kanidmPackage;

      services.kanidm.server.settings = {
        bindaddress = "${services.getVpnIp}:${toString cfg.port}";
        origin = cfg.url;
        domain = domain;
        tls_chain = "/run/credentials/kanidm.service/tls_chain";
        tls_key = "/run/credentials/kanidm.service/tls_key";
      };

      services.kanidm.client.settings = {
        uri = cfg.url;
      };

      services.kanidm.provision = {
        enable = hasProvisioning;
        instanceUrl = "https://${services.getVpnIp}:${toString cfg.port}";
        acceptInvalidCerts = true;
      };

      infra.acme.claims.kanidm = {
        names = [ domain ];
        consumer = {
          kind = "service";
          scope = "kanidm";
        };
        restartServices = [ "kanidm.service" ];
      };

      services.kanidm.server.settings.online_backup = {
        path = "/var/lib/kanidm/backups";
        schedule = "00 22 * * *";
        versions = 7;
      };

      # ── Load ACME certs via systemd credentials ──
      systemd.services.kanidm.serviceConfig.LoadCredential =
        let
          cert = config.infra.acme.claims.kanidm.certificate;
        in
        [
          "tls_chain:${cert.fullchain}"
          "tls_key:${cert.key}"
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
      services.kanidm.server.settings.ldapbindaddress = "${services.getVpnIp}:${toString cfg.ldapPort}";
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

    # ── Application-owned SSO registry → Kanidm provisioning ──
    (lib.mkIf (enabled && sso != { }) {
      services.kanidm.provision = {
        autoRemove = false;
        inherit idmAdminPasswordFile;
      };
      services.kanidm.provision.groups = ssoGroups;
      services.kanidm.provision.systems.oauth2 = ssoOauth2;
    })

    # ── Ingress (global, guarded by URL + backends) ──
    (lib.mkIf (kanidmIps != [ ] && cfg.url != null) {
      infra.ingress."kanidm" = {
        url = cfg.url;
        proxyTo = map (ip: "https://${ip}:${toString cfg.port}") kanidmIps;
        routes.metrics = {
          path = "/metrics";
          nginx.return = "403";
        };
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
        scheme = "https";
        tls_config = {
          insecure_skip_verify = true;
        };
      }) (services.getHostsByTag tag);
    }

  ];
}
