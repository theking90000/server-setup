# -------------------------------------------------------------------------
# oauth2-proxy.nix — SSO par proxy pour les applications sans OIDC natif
#
# Une seule instance oauth2-proxy partagée, colocalisée avec Nginx sur les
# nœuds `web-server`, enregistrée comme un unique client Kanidm
# ("oauth2-proxy"). Chaque application protégée déclare une entrée :
#
#   infra.oauth2Proxy.apps.<app> = {
#     url = "https://app.example.com";   # même URL que son ingress
#     # group = "<app>_users";           # groupe Kanidm requis (défaut)
#   };
#
# Le module génère alors :
#   - le vhost app : `auth_request` nginx vers oauth2-proxy avec
#     `allowed_groups=<group>` (vérification de groupe PAR application) ;
#   - le groupe Kanidm `<app>_users` + un claim `sso_groups` via le
#     registre infra.sso (même mécanique que grafana_role) ;
#   - le flux de login hébergé sur le domaine Kanidm sous /_ssoproxy/
#     (préfixe custom : /oauth2/ entrerait en conflit avec les endpoints
#     OIDC de Kanidm — c'est aussi pourquoi l'intégration nginx upstream
#     `services.oauth2-proxy.nginx`, qui hardcode /oauth2, n'est pas
#     utilisée) ;
#   - le cookie de session sur le domaine parent, partagé entre les
#     nœuds web-server (cookie secret commun).
#
# Activation automatique : aucun tag dédié. Le module s'active quand des
# nœuds `kanidm` et `web-server` existent et qu'au moins une app est
# inscrite. L'ajout d'un utilisateur reste manuel :
#   kanidm group add-members <app>_users <user>
#
# Secrets : secrets/oauth2-proxy.json — cookie_secret (16, 24 ou 32
# octets bruts, ex `openssl rand -hex 16`) et oidc_client_secret (requis
# aussi sur le nœud kanidm, comme grafana).
# -------------------------------------------------------------------------
{
  config,
  lib,
  services,
  ...
}:

let
  cfg = config.infra.oauth2Proxy;
  webTag = "web-server";
  kanidmUrl = config.infra.kanidm.url;

  fleetSsoActive =
    cfg.apps != { }
    && services.getHostsByTag "kanidm" != [ ]
    && services.getHostsByTag webTag != [ ]
    && kanidmUrl != null;
  enabled = services.hasTag webTag && fleetSsoActive;

  parseDomain =
    url:
    let
      m = builtins.match "https?://([^/]+)(/.*)?" url;
    in
    if m != null then builtins.elemAt m 0 else throw "Invalid oauth2Proxy URL: ${url}";

  authDomain = parseDomain kanidmUrl;
  prefix = "/_ssoproxy";
  proxyAddr = "http://127.0.0.1:4180";
  groupsClaim = "sso_groups";
  clientSecretFile = "/run/secrets/sso/oauth2-proxy-client-secret";

  cookieDomain =
    if cfg.cookieDomain != null then
      cfg.cookieDomain
    else
      "." + builtins.elemAt (builtins.match "[^.]+\\.(.*)" authDomain) 0;

  appDomains = lib.mapAttrsToList (_: app: parseDomain app.url) cfg.apps;
in
{
  options.infra.oauth2Proxy = {
    cookieDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Domaine du cookie de session (défaut : parent du domaine Kanidm, ex .example.com).";
    };

    apps = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              url = lib.mkOption {
                type = lib.types.str;
                description = "URL publique de l'application protégée (même que son ingress).";
              };
              group = lib.mkOption {
                type = lib.types.str;
                default = "${name}_users";
                description = "Groupe Kanidm requis pour accéder à l'application.";
              };
            };
          }
        )
      );
      default = { };
      description = "Applications protégées par le proxy SSO.";
    };
  };

  config = lib.mkMerge [
    # ── Client Kanidm unique + un groupe <app>_users par application ──
    (lib.mkIf fleetSsoActive {
      infra.sso.oauth2-proxy = {
        displayName = "SSO Proxy";
        serviceTag = webTag;
        redirectUris = [ "https://${authDomain}${prefix}/callback" ];
        landingUrl = kanidmUrl;
        scopes = [
          "openid"
          "profile"
          "email"
        ];
        groups = lib.mapAttrs (_: app: {
          kanidmName = app.group;
          claims.${groupsClaim} = [ app.group ];
        }) cfg.apps;
      };
    })

    # ── Secret client OIDC : nœuds web-server + kanidm (provisioning) ──
    (lib.mkIf (fleetSsoActive && (services.hasTag webTag || services.hasTag "kanidm")) {
      sops.secrets."sso/oauth2-proxy-client-secret" = {
        sopsFile = config.infra.sops.secretsDirectory + "/oauth2-proxy.json";
        key = "oidc_client_secret";
        owner = if services.hasTag "kanidm" then "kanidm" else "root";
        mode = "0400";
        # rotation : re-provisionner le client Kanidm et recharger le proxy,
        # sinon l'échange de token répond 401 avec l'ancien secret
        restartUnits =
          lib.optional (services.hasTag "kanidm") "kanidm.service"
          ++ lib.optional (services.hasTag webTag) "oauth2-proxy.service";
      };
    })

    # ── Instance locale + câblage nginx (nœuds web-server) ──
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = lib.length (lib.unique appDomains) == lib.length appDomains;
          message = "infra.oauth2Proxy.apps: one domain per app (auth location collision).";
        }
        {
          assertion = !(builtins.elem authDomain appDomains);
          message = "infra.oauth2Proxy.apps: protecting the Kanidm domain itself would gate Kanidm behind its own SSO.";
        }
      ];

      sops.secrets."oauth2-proxy/cookie-secret" = {
        sopsFile = config.infra.sops.secretsDirectory + "/oauth2-proxy.json";
        key = "cookie_secret";
        mode = "0400";
      };

      sops.templates."oauth2-proxy.env" = {
        content = ''
          OAUTH2_PROXY_CLIENT_SECRET=${config.sops.placeholder."sso/oauth2-proxy-client-secret"}
          OAUTH2_PROXY_COOKIE_SECRET=${config.sops.placeholder."oauth2-proxy/cookie-secret"}
        '';
        restartUnits = [ "oauth2-proxy.service" ];
      };

      services.oauth2-proxy = {
        enable = true;
        provider = "oidc";
        clientID = "oauth2-proxy";
        keyFile = config.sops.templates."oauth2-proxy.env".path;
        oidcIssuerUrl = "${kanidmUrl}/oauth2/openid/oauth2-proxy";
        redirectURL = "https://${authDomain}${prefix}/callback";
        scope = "openid profile email";
        email.domains = [ "*" ];
        reverseProxy = true;
        trustedProxyIP = [ "127.0.0.1/32" ];
        setXauthrequest = true;
        cookie = {
          domain = cookieDomain;
          secure = true;
        };
        extraConfig = {
          "proxy-prefix" = prefix;
          "code-challenge-method" = "S256";
          "oidc-groups-claim" = groupsClaim;
          "skip-provider-button" = true;
          "whitelist-domain" = cookieDomain;
        };
      };

      services.nginx.virtualHosts = lib.mkMerge (
        [
          # Flux de login hébergé sur le domaine Kanidm (vhost de l'ingress)
          {
            ${authDomain}.locations."${prefix}/" = {
              proxyPass = proxyAddr;
              extraConfig = ''
                proxy_set_header X-Scheme                $scheme;
                proxy_set_header X-Auth-Request-Redirect $scheme://$host$request_uri;
              '';
            };
          }
        ]
        ++ lib.mapAttrsToList (
          _: app:
          let
            domain = parseDomain app.url;
          in
          {
            ${domain} = {
              extraConfig = ''
                auth_request ${prefix}/auth;
                error_page 401 = @ssoLogin;
              '';

              locations."= ${prefix}/auth" = {
                proxyPass = "${proxyAddr}${prefix}/auth?allowed_groups=${lib.escapeURL app.group}";
                extraConfig = ''
                  internal;
                  auth_request off;
                  proxy_set_header X-Scheme       $scheme;
                  proxy_set_header Content-Length "";
                  proxy_pass_request_body         off;
                '';
              };

              locations."@ssoLogin" = {
                return = "307 https://${authDomain}${prefix}/start?rd=$scheme://$host$request_uri";
                extraConfig = "auth_request off;";
              };
            };
          }
        ) cfg.apps
      );
    })
  ];
}
