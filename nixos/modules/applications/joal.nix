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
      description = "URL publique optionnelle de la WebUI JOAL (ex: https://joal.example.com).";
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

      infra.security.acls = [
        {
          port = cfg.webuiPort;
          allowedTags = [ "web-server" ];
          description = "JOAL WebUI";
        }
      ];

      infra.backup.paths = [ stateDir ];
    })

    (lib.mkIf (services.getVpnIpsByTag tag != [ ] && cfg.url != null) {
      infra.ingress.joal = {
        url = cfg.url;
        proxyTo = map (ip: "http://${ip}:${toString cfg.webuiPort}") (services.getVpnIpsByTag tag);
      };
    })
  ];
}
