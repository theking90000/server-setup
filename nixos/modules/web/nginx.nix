# -------------------------------------------------------------------------
# nginx.nix — Compilateur ingress → Nginx (vhosts, claims ACME, upstreams)
#
# Sur les nœuds `web-server`, compile les entrées `infra.ingress` :
#
#   - normalise endpoint + routes (jointure basePath, modes exact/prefix) ;
#   - groupe par hôte : plusieurs entrées peuvent partager un hôte avec
#     des routes différentes, seuls les doublons exacts
#     (hôte + chemin + mode) sont rejetés ;
#   - génère un claim ACME de scope `nginx` par entrée (couverture
#     wildcard) et câble le certificat via useACMEHost ;
#   - génère un upstream par route avec backend(s) ;
#   - un hôte wildcard produit un server_name regex limité à un seul
#     label (aligné sur la portée du wildcard X.509), avec la capture
#     `$infra_subdomain` disponible dans les fragments.
#
# Champs possédés par le compilateur (non remplaçables par un fragment) :
# clé de location, serverName, forceSSL, useACMEHost, écoute et TLS.
# -------------------------------------------------------------------------
{
  config,
  pkgs,
  lib,
  services,
  acme,
  ...
}:

let
  cfg = config.infra.ingress;
  tag = "web-server";
  enabled = services.hasTag tag;
  metricsPort = 9113;

  # ── Normalisation ─────────────────────────────────────────────────────
  parseUrl = url: builtins.match "([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]+)(/[^?#]*)?" (toString url);

  pathRe = "(/[A-Za-z0-9._~-]+)*/?";
  validPath = p: !lib.hasInfix ".." p && builtins.match pathRe p != null;

  joinPath =
    base: path:
    let
      b = lib.removeSuffix "/" base;
    in
    if path == "/" then (if b == "" then "/" else "${b}/") else "${b}${path}";

  backendParts = backend: builtins.match "(https?)://([^/]+)" backend;

  entryList = lib.mapAttrsToList (
    name: entry:
    let
      host = entry.endpoint.host;
      basePath = entry.endpoint.basePath;
    in
    {
      inherit name entry host basePath;
      routes = lib.mapAttrsToList (
        rname: route:
        let
          fullPath = joinPath basePath route.path;
          backends = if route.proxyTo == null then [ ] else lib.toList route.proxyTo;
          parts = map backendParts backends;
        in
        {
          inherit
            rname
            route
            fullPath
            backends
            parts
            ;
          locationKey = if route.match == "exact" then "= ${fullPath}" else fullPath;
          upstreamName = "ig-${name}-${rname}";
          schemes = lib.unique (map (p: lib.head p) (lib.filter (p: p != null) parts));
        }
      ) entry.routes;
    }
  ) cfg;

  routedEntries = lib.filter (e: e.host != null) entryList;

  # ── Rejets à l'évaluation ─────────────────────────────────────────────
  routeKeys = lib.concatMap (e: map (r: "${e.host} ${r.locationKey}") e.routes) routedEntries;
  duplicateKeys = lib.attrNames (lib.filterAttrs (_: n: n > 1) (lib.foldl' (
    acc: k: acc // { ${k} = (acc.${k} or 0) + 1; }
  ) { } routeKeys));

  ingressErrors =
    lib.concatMap (
      e:
      let
        prefix = "infra.ingress.${e.name}";
        parsed = parseUrl e.entry.url;
      in
      lib.optional (e.entry.url != null && parsed == null) "${prefix}: invalid url '${e.entry.url}'"
      ++
        lib.optional (e.entry.url != null && parsed != null && lib.head parsed != "https")
          "${prefix}: url must be HTTPS (ingress endpoints are HTTPS only)"
      ++
        lib.optional (e.entry.url != null && parsed != null && e.host != builtins.elemAt parsed 1)
          "${prefix}: url host '${builtins.elemAt parsed 1}' conflicts with endpoint.host '${toString e.host}'"
      ++ lib.optional (
        e.entry.url == null && e.host == null
      ) "${prefix}: either url or endpoint.host is required"
      ++
        lib.optional (e.host != null && !acme.validDnsName e.host)
          "${prefix}: invalid endpoint host '${e.host}'"
      ++
        lib.optional (!lib.hasPrefix "/" e.basePath || !validPath e.basePath)
          "${prefix}: invalid basePath '${e.basePath}'"
      ++ lib.concatMap (
        r:
        let
          rprefix = "${prefix}.routes.${r.rname}";
        in
        lib.optional (
          !lib.hasPrefix "/" r.route.path || !validPath r.route.path
        ) "${rprefix}: invalid path '${r.route.path}'"
        ++ lib.concatMap (
          i:
          lib.optional (builtins.elemAt r.parts i == null)
            "${rprefix}: invalid backend '${builtins.elemAt r.backends i}' (expected http(s)://host:port)"
        ) (lib.range 0 (lib.length r.backends - 1))
        ++
          lib.optional (lib.length r.schemes > 1)
            "${rprefix}: backends mix http and https schemes"
        ++
          lib.optional (r.backends != [ ] && r.route.nginx ? proxyPass)
            "${rprefix}: proxyPass is owned by the compiler when proxyTo is set"
        ++
          lib.optional (r.backends == [ ] && r.route.nginx == { })
            "${rprefix}: route needs proxyTo or a nginx fragment"
      ) e.routes
    ) entryList
    ++ map (k: "infra.ingress: duplicate route for '${k}' across entries") duplicateKeys;

  # ── Génération ────────────────────────────────────────────────────────
  byHost = lib.groupBy (e: e.host) routedEntries;

  logName = host: lib.replaceStrings [ "*" ] [ "_" ] host;

  mkLocation =
    r:
    let
      scheme = if r.schemes == [ ] then "http" else lib.head r.schemes;
      sslExtra = lib.optionalString (r.backends != [ ] && scheme == "https") "proxy_ssl_verify off;\n";
      extra = sslExtra + (r.route.nginx.extraConfig or "");
    in
    lib.optionalAttrs (r.backends != [ ]) {
      proxyPass = "${scheme}://${r.upstreamName}${lib.optionalString (r.route.forwardPath == "strip-prefix") "/"}";
      proxyWebsockets = true;
    }
    // builtins.removeAttrs r.route.nginx [ "extraConfig" ]
    // lib.optionalAttrs (extra != "") { extraConfig = extra; };

  mkVhost =
    host: entries:
    let
      isWildcard = acme.isWildcardName host;
      parent = acme.baseName host;
      escapedParent = lib.replaceStrings [ "." ] [ "\\." ] parent;
      certName = config.infra.acme.claims."ingress-${(lib.head entries).name}".certificate.name;
    in
    {
      serverName = if isWildcard then "~^(?<infra_subdomain>[^.]+)\\.${escapedParent}$" else host;
      forceSSL = true;
      useACMEHost = certName;

      extraConfig = ''
        error_log /var/log/nginx/${logName host}_error.log;
        access_log /var/log/nginx/${logName host}_access.log;
      ''
      + lib.concatStrings (map (e: e.entry.nginx.extraConfig) entries);

      # Les routes en doublon (hôte + chemin + mode) sont exclues de la
      # génération : l'assertion agrégée les rejette déjà, et les garder
      # produirait un conflit de merge illisible avant son affichage.
      locations = lib.mkMerge (
        map (
          e:
          lib.listToAttrs (
            map (r: {
              name = r.locationKey;
              value = mkLocation r;
            }) (lib.filter (r: !(lib.elem "${host} ${r.locationKey}" duplicateKeys)) e.routes)
          )
        ) entries
      );
    };
in
{
  config = lib.mkMerge [
    # Module contract
    { infra.registeredTags = [ tag ]; }

    # Local configuration
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

      # Default reject
      services.nginx.virtualHosts."_" = {
        default = true;
        rejectSSL = true;
        http2 = false;
        locations."/" = {
          return = "444";
        };
      };

      # VTS metrics on VPN
      services.nginx.virtualHosts."stats.localhost" = {
        listen = [
          {
            addr = services.getVpnIp;
            port = metricsPort;
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
          port = metricsPort;
          allowedTags = [ "prometheus" ];
          description = "NGINX VTS Metrics";
        }
      ];
    })

    # Local ingress aggregation
    (lib.mkIf (enabled && cfg != { }) {
      assertions = map (e: {
        assertion = false;
        message = e;
      }) ingressErrors;

      # Claims ACME : un par entrée, scope nginx, couverture wildcard.
      # Le groupe de certificat est câblé sur le vhost via useACMEHost et
      # nginx est rechargé après chaque renouvellement réel.
      infra.acme.claims = lib.mapAttrs' (
        name: entry:
        lib.nameValuePair "ingress-${name}" {
          names = [ entry.endpoint.host ];
          consumer = {
            kind = "ingress";
            scope = "nginx";
          };
          coverage = "wildcard";
          group = "nginx";
          reloadServices = [ "nginx.service" ];
        }
      ) (lib.filterAttrs (_: entry: entry.endpoint.host != null) cfg);

      # Upstreams : un par route avec backend(s)
      services.nginx.upstreams = lib.listToAttrs (
        lib.concatMap (
          e:
          map (r: {
            name = r.upstreamName;
            value = {
              servers = lib.genAttrs (map (p: builtins.elemAt p 1) (lib.filter (p: p != null) r.parts)) (
                _: { }
              );
            };
          }) (lib.filter (r: r.backends != [ ]) e.routes)
        ) routedEntries
      );

      # VirtualHosts : un par hôte, routes de toutes les entrées fusionnées
      services.nginx.virtualHosts = lib.mapAttrs mkVhost byHost;
    })

    # Fleet-wide contributions
    {
      infra.telemetry."nginx" = map (host: {
        targets = [ "${host}:${toString metricsPort}" ];
        labels = { inherit host; };
      }) (services.getHostsByTag tag);
    }

    (lib.mkIf (services.getHostsByTag tag != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/nginx-vts.json ];
    })
  ];
}
