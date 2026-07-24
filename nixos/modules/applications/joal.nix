# -------------------------------------------------------------------------
# joal.nix — Client d'annonce BitTorrent pour tester un tracker custom
#
# JOAL ne crée aucun réseau. Il rejoint obligatoirement le namespace
# WireGuard de qBittorrent et hérite ainsi de son kill switch structurel :
# aucune route de repli par l'IP publique du nœud n'existe.
#
# Le module possède son tag, ses secrets, son utilisateur, son état et son
# ingress. Le seul contrat partagé avec qBittorrent est
# `infra.qbittorrent.networkNamespace`.
#
# Tags requis sur le même nœud :
#   - `applications/joal`
#   - `applications/qbittorrent`
# -------------------------------------------------------------------------
{
  config,
  lib,
  pkgs,
  services,
  ...
}:

let
  cfg = config.infra.joal;
  tag = "applications/joal";
  qbittorrentTag = "applications/qbittorrent";
  enabled = services.hasTag tag;
  qbittorrentEnabled = services.hasTag qbittorrentTag;

  netns = config.infra.qbittorrent.networkNamespace;
  stateDir = "/var/lib/joal";
  package = pkgs.callPackage ../../pkgs/joal { };
  initialConfig = pkgs.writeText "joal-config.json" (builtins.toJSON cfg.settings);
  bootstrapPort = cfg.webuiPort + 1;
  parsedUrl =
    if cfg.url == null then
      null
    else
      builtins.match "https?://[^/?#]+(/[^?#]*)?" cfg.url;
  urlPath =
    if parsedUrl == null || builtins.elemAt parsedUrl 0 == null then
      null
    else
      lib.removeSuffix "/" (builtins.elemAt parsedUrl 0);
  webuiBackends =
    map (ip: "http://${ip}:${toString cfg.webuiPort}") (services.getVpnIpsByTag tag);
  bootstrapBackends =
    map (ip: "http://${ip}:${toString bootstrapPort}") (services.getVpnIpsByTag tag);
  uiBootstrap = pkgs.writeShellScript "joal-ui-bootstrap" ''
    IFS= read -r _request_line || exit 0
    while IFS= read -r header; do
      [ "$header" = $'\r' ] && break
    done

    ui_path=$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/ui-path")
    ui_secret=$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/ui-secret")
    printf -v body \
      'localStorage.setItem("guiConfig",JSON.stringify({host:window.location.hostname,port:window.location.port||("https:"===window.location.protocol?"443":"80"),pathPrefix:"%s",secretToken:"%s"}));' \
      "$ui_path" "$ui_secret"

    printf 'HTTP/1.1 200 OK\r\n'
    printf 'Content-Type: application/javascript; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf 'X-Content-Type-Options: nosniff\r\n'
    printf 'Content-Length: %s\r\n' "''${#body}"
    printf 'Connection: close\r\n\r\n'
    printf '%s' "$body"
  '';
  runner = pkgs.writeShellScript "joal-run" ''
    exec ${lib.getExe package} \
      --joal-conf=${stateDir} \
      --spring.main.web-environment=true \
      --server.address=${netns.namespaceAddress} \
      --server.port=${toString cfg.webuiPort} \
      --spring.config.additional-location=file:/run/joal/application.properties
  '';
in
{
  options.infra.joal = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        URL publique optionnelle de JOAL (ex: https://joal.example.com ou
        https://qbt.example.com/joal). Pour un sous-chemin, sa dernière
        composante doit correspondre au secret ui_path ; l'UI est alors sous
        /<ui_path>/ui/ et le WebSocket sous /<ui_path>.
      '';
    };

    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 8091;
      description = "Port de la WebUI JOAL, relayé du netns qBittorrent vers le mesh.";
    };

    settings = lib.mkOption {
      description = "Configuration JOAL écrite lors du premier démarrage.";
      default = { };
      type = lib.types.submodule {
        options = {
          minUploadRate = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 30;
            description = "Débit montant simulé minimal en Kio/s.";
          };
          maxUploadRate = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 170;
            description = "Débit montant simulé maximal en Kio/s.";
          };
          simultaneousSeed = lib.mkOption {
            type = lib.types.ints.positive;
            default = 20;
            description = "Nombre maximal de torrents annoncés simultanément.";
          };
          client = lib.mkOption {
            type = lib.types.str;
            default = "qbittorrent-5.2.2.client";
            description = "Profil client JOAL à utiliser.";
          };
          keepTorrentWithZeroLeechers = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Conserver les torrents sans leechers actifs.";
          };
          uploadRatioTarget = lib.mkOption {
            type = lib.types.either lib.types.int lib.types.float;
            default = -1.0;
            description = "Ratio de session cible ; -1 conserve le torrent sans limite.";
          };
        };
      };
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }

    (lib.mkIf enabled {
      assertions = [
        {
          assertion = qbittorrentEnabled;
          message = "Le tag applications/joal exige applications/qbittorrent sur le même nœud.";
        }
        {
          assertion = cfg.settings.minUploadRate <= cfg.settings.maxUploadRate;
          message = "infra.joal.settings.minUploadRate doit être inférieur ou égal à maxUploadRate.";
        }
        {
          assertion = cfg.webuiPort < 65535;
          message = "infra.joal.webuiPort doit laisser le port suivant libre pour le bootstrap runtime de la WebUI.";
        }
      ];

      sops.secrets."joal/ui-path" = {
        sopsFile = config.infra.sops.secretsDirectory + "/joal.json";
        key = "ui_path";
        mode = "0400";
        restartUnits = [ "joal.service" ];
      };

      sops.secrets."joal/ui-secret" = {
        sopsFile = config.infra.sops.secretsDirectory + "/joal.json";
        key = "ui_secret";
        mode = "0400";
        restartUnits = [ "joal.service" ];
      };

      users.users.joal = {
        isSystemUser = true;
        group = "joal";
        home = stateDir;
        createHome = false;
      };
      users.groups.joal = { };

      systemd.services.joal = {
        description = "JOAL tracker test client";
        wantedBy = [ "multi-user.target" ];
        bindsTo = [ netns.unit ];
        after = [ netns.unit ];
        path = [
          pkgs.coreutils
          pkgs.gnugrep
        ];
        serviceConfig = {
          User = "joal";
          Group = "joal";
          StateDirectory = "joal";
          StateDirectoryMode = "0750";
          RuntimeDirectory = "joal";
          RuntimeDirectoryMode = "0700";
          WorkingDirectory = stateDir;
          LoadCredential = [
            "ui-path:/run/secrets/joal/ui-path"
            "ui-secret:/run/secrets/joal/ui-secret"
          ];
          ExecStart = runner;
          Restart = "on-failure";
          RestartSec = 10;
          UMask = "0077";
          NetworkNamespacePath = netns.path;
          BindReadOnlyPaths = [ "${netns.resolvConf}:/etc/resolv.conf" ];
          # incompatible avec l'entrée dans un netns possédé par le user ns initial
          PrivateUsers = lib.mkForce false;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          NoNewPrivileges = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          CapabilityBoundingSet = "";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };
        preStart = ''
          install -d -m0750 "$STATE_DIRECTORY/clients" \
            "$STATE_DIRECTORY/torrents/archived"
          cp -f ${package}/share/joal/clients/*.client \
            "$STATE_DIRECTORY/clients/"

          if [ ! -e "$STATE_DIRECTORY/config.json" ]; then
            install -m0600 ${initialConfig} "$STATE_DIRECTORY/config.json"
          fi

          ui_path=$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/ui-path")
          ui_secret=$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/ui-secret")
          if ! printf '%s' "$ui_path" | grep -Eq '^[[:alnum:]]+$'; then
            echo "ui_path doit être une valeur alphanumérique non vide" >&2
            exit 1
          fi
          if ! printf '%s' "$ui_secret" | grep -Eq '^[[:alnum:]]+$'; then
            echo "ui_secret doit être une valeur alphanumérique non vide" >&2
            exit 1
          fi

          {
            printf 'joal.ui.path.prefix=%s\n' "$ui_path"
            printf 'joal.ui.secret-token=%s\n' "$ui_secret"
          } > "$RUNTIME_DIRECTORY/application.properties"
          chmod 0400 "$RUNTIME_DIRECTORY/application.properties"
        '';
      };

      # JOAL écoute uniquement sur le veth interne. Le socket host ne donne
      # accès qu'à la WebUI ; les annonces tracker restent dans le netns.
      systemd.sockets.joal-webui = {
        description = "Socket WebUI JOAL sur le mesh";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "${services.getVpnIp}:${toString cfg.webuiPort}" ];
        socketConfig.FreeBind = true;
      };

      systemd.services.joal-webui = {
        description = "Proxy WebUI JOAL (wg0 -> netns qBittorrent)";
        requires = [ "joal.service" ];
        after = [ "joal.service" ];
        serviceConfig.ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${netns.namespaceAddress}:${toString cfg.webuiPort}";
      };

      # Le WebUI upstream mémorise sa connexion dans localStorage et prend
      # encore le port 80 par défaut derrière un reverse proxy HTTPS. Ce petit
      # endpoint, servi uniquement sur le mesh et protégé par le SSO public,
      # injecte la configuration correcte avant le bundle JOAL. Le token est
      # lu à l'exécution : il ne rejoint ni le Nix store, ni une URL.
      systemd.sockets.joal-ui-bootstrap = {
        description = "Socket du bootstrap runtime de la WebUI JOAL";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "${services.getVpnIp}:${toString bootstrapPort}" ];
        socketConfig = {
          Accept = true;
          FreeBind = true;
        };
      };

      systemd.services."joal-ui-bootstrap@" = {
        description = "Bootstrap runtime de la WebUI JOAL";
        requires = [ "joal.service" ];
        after = [ "joal.service" ];
        serviceConfig = {
          User = "joal";
          Group = "joal";
          ExecStart = uiBootstrap;
          StandardInput = "socket";
          StandardOutput = "socket";
          StandardError = "journal";
          LoadCredential = [
            "ui-path:/run/secrets/joal/ui-path"
            "ui-secret:/run/secrets/joal/ui-secret"
          ];
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateDevices = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          CapabilityBoundingSet = "";
        };
      };

      infra.security.acls = [
        {
          port = cfg.webuiPort;
          allowedTags = [ "web-server" ];
          description = "JOAL WebUI";
        }
        {
          port = bootstrapPort;
          allowedTags = [ "web-server" ];
          description = "Bootstrap runtime de la WebUI JOAL";
        }
      ];

      infra.backup.paths = [ stateDir ];
    })

    (lib.mkIf (services.getVpnIpsByTag tag != [ ] && cfg.url != null) {
      # Quand cette URL partage le domaine qBittorrent, le auth_request SSO
      # déjà posé au niveau du vhost protège également cette location et son
      # WebSocket. Enregistrer une seconde app oauth2-proxy sur le même
      # domaine créerait deux handlers /_ssoproxy/auth concurrents.
      infra.ingress.joal =
        if urlPath == null || urlPath == "" then
          {
            url = cfg.url;
            proxyTo = webuiBackends;
          }
        else
          {
            url = cfg.url;
            # JOAL sert l'UI sous /<ui_path>/ui/, mais son handshake
            # WebSocket vise exactement /<ui_path> sans slash final.
            # Les deux routes doivent donc précéder le catch-all "/" de
            # qBittorrent lorsque les applications partagent un domaine.
            endpoint.basePath = "/";
            routes.websocket = {
              path = urlPath;
              match = "exact";
              proxyTo = webuiBackends;
            };
            routes.bootstrap = {
              path = "${urlPath}/ui/bootstrap.js";
              match = "exact";
              proxyTo = bootstrapBackends;
              nginx.extraConfig = ''
                proxy_no_cache 1;
                proxy_cache_bypass 1;
              '';
            };
            routes.webui = {
              path = "${urlPath}/";
              proxyTo = webuiBackends;
              nginx.extraConfig = ''
                # Un Web App Manifest est chargé sans cookies par défaut.
                # Sans cet attribut, oauth2-proxy le redirige vers le login
                # cross-origin et le navigateur bloque la réponse par CORS.
                proxy_set_header Accept-Encoding "";
                sub_filter_once on;
                sub_filter '<link rel="manifest" href="./manifest.json"/>' '<link rel="manifest" crossorigin="use-credentials" href="./manifest.json"/>';
                sub_filter '<script>!function(l)' '<script src="./bootstrap.js"></script><script>!function(l)';
              '';
            };
          };
    })
  ];
}
