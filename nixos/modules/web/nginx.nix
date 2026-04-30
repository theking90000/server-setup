# -------------------------------------------------------------------------
# nginx.nix — Reverse proxy Nginx + VTS, ingress → virtualHosts
#
# Parse les entrées `infra.ingress` (URL ou domain+path), groupe par
# domaine, et génère un virtualHost nginx par domaine avec les locations
# correspondant aux chemins de chaque entrée.
#
# Support multi-domaine par chemins :
#   { url = "https://apps.exemple.com/app1"; backend = [...]; }
#   { url = "https://apps.exemple.com/app2"; backend = [...]; }
#   → 1 seul virtualHost "apps.exemple.com" avec /app1 → upstream1, /app2 → upstream2
# -------------------------------------------------------------------------
{
  config,
  pkgs,
  lib,
  services,
  ...
}:

let
  TAG = "web-server";
  enabled = services.hasTag TAG;
  getVal = local: global: if local != null then local else global;

  # --- URL parsing ---
  # "https://example.com/app"  → { domain = "example.com"; path = "/app"; }
  # "https://example.com"      → { domain = "example.com"; path = null; }
  parseUrl = url:
    let
      m = builtins.match "https?://([^/]+)(/.*)?" url;
    in
      if m == null then throw "Invalid ingress URL: ${url}"
      else {
        domain = builtins.elemAt m 0;
        path = builtins.elemAt m 1;
      };

  # --- Resolve domain + path for each ingress entry ---
  resolveSite = name: site:
    let
      parsed =
        if site.url != null then
          parseUrl site.url
        else if site.domain != null then
          { domain = site.domain; path = site.path; }
        else throw "Ingress entry '${name}': either 'url' or 'domain' is required.";
    in
      site // {
        _name = name;
        _domain = parsed.domain;
        _path = parsed.path;
      };

  # All resolved ingress entries as a list
  resolvedEntries = lib.mapAttrsToList resolveSite config.infra.ingress;

  # Group by effective domain
  ingressByDomain = lib.groupBy (e: e._domain) resolvedEntries;

in
{
  config = lib.mkMerge [
    { infra.registeredTags = [ TAG ]; }

    # --- Nginx core config ---
    (lib.mkIf enabled {
      services.nginx = {
        enable = true;
        additionalModules = [ pkgs.nginxModules.vts ];

        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;

        serverTokens = false;

        appendHttpConfig = ''
          vhost_traffic_status_zone;
          vhost_traffic_status_histogram_buckets 0.005 0.01 0.05 0.1 0.5 1 5 10;
        '';
      };

      users.users.nginx.extraGroups =
        lib.optional (builtins.hasAttr "acme" config.users.groups) "acme"
        ++ lib.optional (builtins.hasAttr "cert-syncer" config.users.groups) "cert-syncer";

      # Default reject
      services.nginx.virtualHosts."_" = {
        default = true;
        rejectSSL = true;
        http2 = false;
        locations."/" = { return = "444"; };
      };

      # VTS metrics on VPN
      services.nginx.virtualHosts."stats.localhost" = {
        listen = [
          {
            addr = services.getVpnIp;
            port = 9113;
          }
        ];
        locations."/metrics" = {
          extraConfig = ''
            vhost_traffic_status_display;
            vhost_traffic_status_display_format prometheus;
          '';
        };
      };

      networking.firewall.allowedTCPPorts = [
        80
        443
      ];

      infra.security.acls = [
        {
          port = 9113;
          allowedTags = [ "prometheus" ];
          description = "NGINX VTS Metrics";
        }
      ];
    })

    # --- Ingress → upstreams + virtualHosts (if enabled AND at least one ingress entry) ---
    (lib.mkIf (enabled && config.infra.ingress != { }) {

      # Upstreams : un par entrée ingress (même nom de clé)
      services.nginx.upstreams = lib.mapAttrs (name: site: {
        servers = lib.genAttrs site.backend (addr: { });
      }) config.infra.ingress;

      # ACME domains : dédupliqués par domaine effectif
      infra.acme.domains =
        let
          domainNames = lib.unique (
            map (e: e._domain) (
              builtins.filter (e: e.sslCertificate == null) resolvedEntries
            )
          );
        in
          map (d: { domain = d; }) domainNames;

      # VirtualHosts : un par domaine effectif, avec locations par chemin
      services.nginx.virtualHosts = lib.mapAttrs (
        domain: entries:
        let
          primaryEntry = builtins.head entries;
          certName = getVal primaryEntry.sslCertificate domain;
        in
          {
            serverName = domain;
            forceSSL = true;

            sslCertificate = "/var/lib/acme/${certName}/fullchain.pem";
            sslCertificateKey = "/var/lib/acme/${certName}/key.pem";
            sslTrustedCertificate = "/var/lib/acme/${certName}/chain.pem";

            extraConfig = ''
              error_log /var/log/nginx/${domain}_error.log;
              access_log /var/log/nginx/${domain}_access.log;
            '';

            locations = lib.mkMerge (
              map (
                entry:
                let
                  locPath = if entry._path != null then entry._path else "/";
                  prefix = if locPath == "/" then "" else locPath;
                in
                  {
                    "${locPath}" = {
                      proxyPass = "http://${entry._name}";
                      proxyWebsockets = true;
                    };
                  }
                  // lib.listToAttrs (
                    map (p: {
                      name = "${prefix}${p}";
                      value = { return = "403"; };
                    }) (entry.blockPaths or [ ])
                  )
              ) entries
            );
          }
      ) ingressByDomain;
    })

    # --- Telemetry ---
    {
      infra.telemetry."nginx" = map (host: {
        targets = [ "${host}:9113" ];
        labels = { inherit host; };
      }) (services.getHostsByTag TAG);
    }

    (lib.mkIf (services.getHostsByTag TAG != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/nginx-vts.json ];
    })
  ];
}
