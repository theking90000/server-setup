# -------------------------------------------------------------------------
# servarr.nix — Radarr et Sonarr
#
# Un seul fichier pour deux applications strictement identiques dans leur
# forme : même socle .NET, même schéma de configuration, mêmes
# intégrations. Chacune garde son tag, son secret, son port, son ingress et
# son exporteur.
#
# Configuration : les applications *arr se configurent par variables
# d'environnement `<APP>__<SECTION>__<CLE>` (schéma Servarr officiel, exposé
# par nixpkgs via `services.<app>.settings`). Nix impose donc l'adresse
# d'écoute (IP wg0), le port et la méthode d'authentification ; SOPS impose
# la clé d'API via `environmentFiles`. Les variables gagnent toujours sur le
# config.xml écrit par l'application.
#
# Authentification :
#   - un nœud `kanidm` existe et `url` est définie : `AuthenticationMethod`
#     vaut `External`, l'application délègue au reverse proxy et l'accès est
#     filtré par oauth2-proxy (groupe Kanidm `<app>_users`) ;
#   - sinon : `Forms`, avec un compte local créé au premier démarrage.
#
# `External` fait confiance à TOUT ce qui atteint le port : l'ACL n'autorise
# donc que les nœuds `web-server` et l'IP wg0 locale, seule source possible
# pour l'exporteur. L'API reste utilisable par clé (`X-Api-Key`) dans les
# deux cas, sans passer par le SSO — c'est ainsi que l'exporteur travaille.
#
# Stockage : les *arr lisent le dossier de téléchargement de qBittorrent et
# écrivent dans la médiathèque. Le module crée un groupe partagé `media`,
# pose un setgid sur le dossier de téléchargement quand qBittorrent tourne
# sur le même nœud, et force UMask=0002 des deux côtés pour que l'import
# puisse déplacer et supprimer les fichiers. Le montage de la médiathèque
# reste déclaré dans le dépôt privé (`infra.rcloneSync.mounts`), avec
# `gid=` et `umask=002` alignés sur ce groupe.
#
# NON DÉCLARATIF : download client, root folders, indexeurs, profils de
# qualité, listes et notifications vivent dans la base SQLite de
# l'application. Le guide des opérations manuelles est en commentaire dans
# `config/radarr/radarr.nix` et `config/sonarr/sonarr.nix`.
#
# Tags : `applications/radarr`, `applications/sonarr`
# -------------------------------------------------------------------------
{
  config,
  lib,
  pkgs,
  services,
  ...
}:

let
  mediaCfg = config.infra.servarr.mediaGroup;

  qbittorrentTag = "applications/qbittorrent";
  # Chemin de sauvegarde par défaut de qBittorrent (--profile) : c'est ce
  # dossier que les *arr doivent pouvoir lire, puis vider après import.
  qbittorrentDownloadDir =
    (lib.removeSuffix "/" config.services.qbittorrent.profileDir) + "/qBittorrent/downloads";

  apps = {
    radarr = {
      displayName = "Radarr";
      port = 7878;
      metricsPort = 9708;
      stateDir = "/var/lib/radarr";
      database = "radarr.db";
      dashboard = ./dashboards/radarr.json;
    };
    sonarr = {
      displayName = "Sonarr";
      port = 8989;
      metricsPort = 9709;
      stateDir = "/var/lib/sonarr";
      database = "sonarr.db";
      dashboard = ./dashboards/sonarr.json;
    };
  };

  appTag = name: "applications/${name}";
  appEnabled = name: services.hasTag (appTag name);
  anyEnabled = lib.any appEnabled (lib.attrNames apps);

  mkUrlOption =
    displayName:
    lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique de ${displayName} (ex: https://${lib.toLower displayName}.example.com).";
    };

  mkApp =
    name: app:
    let
      cfg = config.infra.${name};
      tag = appTag name;
      enabled = appEnabled name;
      # Présence globale de Kanidm : le garde SSO est posé par oauth2-proxy
      # sur les nœuds web-server, pas forcément sur celui de l'application.
      ssoEnabled = services.getHostsByTag "kanidm" != [ ] && cfg.url != null;
      dataDir = config.services.${name}.dataDir;
      dbBackupDir = "${app.stateDir}/db-backup";
      exporter = "exportarr-${name}";
      exporterUnit = "prometheus-${exporter}-exporter.service";
    in
    lib.mkMerge [
      # Module contract
      { infra.registeredTags = [ tag ]; }

      # Local configuration
      (lib.mkIf enabled {
        warnings = lib.optional (cfg.url != null && !ssoEnabled) ''
          infra.${name}: aucun nœud kanidm dans la flotte, ${cfg.url} est publié
          avec l'authentification interne ${app.displayName} (formulaire) au lieu du SSO.
        '';

        sops.secrets."${name}/api-key" = {
          sopsFile = config.infra.sops.secretsDirectory + "/${name}.json";
          key = "api_key";
          mode = "0400";
          restartUnits = [
            "${name}.service"
            exporterUnit
          ];
        };

        sops.templates."${name}.env" = {
          content = ''
            ${lib.toUpper name}__AUTH__APIKEY=${config.sops.placeholder."${name}/api-key"}
          '';
          mode = "0400";
          restartUnits = [ "${name}.service" ];
        };

        services.${name} = {
          enable = true;
          settings = {
            server = {
              bindaddress = services.getVpnIp;
              inherit (app) port;
            };
            auth = {
              # External : l'application fait confiance au reverse proxy SSO.
              method = if ssoEnabled then "External" else "Forms";
              required = "Enabled";
            };
          };
          environmentFiles = [ config.sops.templates."${name}.env".path ];
        };

        systemd.services.${name}.serviceConfig = {
          # Import : écriture dans la médiathèque et purge du dossier de
          # téléchargement, tous deux partagés via le groupe media.
          SupplementaryGroups = [ mediaCfg.name ];
          # nixpkgs durcit l'unité avec UMask=0022 et PrivateUsers : le
          # premier écrit des fichiers non modifiables par le groupe, le
          # second place le service dans un user namespace où le GID media
          # n'est pas mappé. Les deux annulent le partage de fichiers.
          UMask = lib.mkForce "0002";
          PrivateUsers = lib.mkForce false;
        };

        # L'exporteur tourne sur le nœud de l'application et l'interroge par
        # son IP wg0 avec la clé d'API : il ne traverse pas le SSO.
        services.prometheus.exporters.${exporter} = {
          enable = true;
          url = "http://${services.getVpnIp}:${toString app.port}";
          apiKeyFile = config.sops.secrets."${name}/api-key".path;
          port = app.metricsPort;
          # L'option listenAddress n'est pas câblée par le module exportarr.
          environment.INTERFACE = services.getVpnIp;
        };

        infra.security.acls = [
          {
            inherit (app) port;
            allowedTags = [ "web-server" ];
            # L'exporteur local sort par l'IP wg0 du nœud, et le garde SSO
            # d'un `AuthenticationMethod=External` ne vit que côté nginx.
            allowedIps = [ services.getVpnIp ];
            description = "${app.displayName} WebUI";
          }
          {
            port = app.metricsPort;
            allowedTags = [ "prometheus" ];
            description = "${app.displayName} exporter";
          }
        ];

        infra.backup = {
          paths = [ app.stateDir ];
          # La base est en WAL et le service tourne pendant la sauvegarde :
          # une copie fichier serait incohérente. `.backup` produit un
          # instantané exploitable, déposé dans le chemin déjà sauvegardé.
          # Les logs (logs.db) ne sont pas dumpés, ils sont reconstructibles.
          prepareCommands = [
            ''
              install -d -m 0750 -o ${name} -g ${name} ${dbBackupDir}
              dump=${dbBackupDir}/${app.database}
              tmp="$dump.tmp"
              rm -f "$tmp"
              trap 'rm -f "$tmp"' EXIT
              ${pkgs.util-linux}/bin/runuser -u ${name} -- \
                ${lib.getExe pkgs.sqlite} ${dataDir}/${app.database} ".backup '$tmp'"
              mv "$tmp" "$dump"
              chmod 0640 "$dump"
              trap - EXIT
            ''
          ];
        };
      })

      # Fleet-wide contributions
      {
        infra.telemetry.${name} = map (host: {
          targets = [ "${host}:${toString app.metricsPort}" ];
          labels = { inherit host; };
        }) (services.getHostsByTag tag);
      }

      (lib.mkIf (services.getHostsByTag tag != [ ]) {
        infra.grafana.dashboards = [ app.dashboard ];
      })

      (lib.mkIf (services.getVpnIpsByTag tag != [ ] && ssoEnabled) {
        infra.oauth2Proxy.apps.${name}.url = cfg.url;
      })

      (lib.mkIf (services.getVpnIpsByTag tag != [ ] && cfg.url != null) {
        infra.ingress.${name} = {
          url = cfg.url;
          proxyTo = map (ip: "http://${ip}:${toString app.port}") (services.getVpnIpsByTag tag);
        };
      })
    ];
in
{
  options.infra = {
    radarr.url = mkUrlOption "Radarr";
    sonarr.url = mkUrlOption "Sonarr";

    servarr.mediaGroup = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        internal = true;
        description = ''
          Vrai quand Radarr ou Sonarr tourne sur ce nœud, donc quand le groupe
          partagé existe. Lu par le dépôt privé pour n'aligner les options du
          montage de médiathèque (`gid=`, `umask=`) que dans ce cas.
        '';
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "media";
        readOnly = true;
        internal = true;
        description = "Nom du groupe partageant médiathèque et téléchargements.";
      };

      gid = lib.mkOption {
        type = lib.types.int;
        default = 2000;
        description = ''
          GID fixe du groupe media. Une valeur fixe est nécessaire : un
          montage FUSE ne connaît que des GID numériques, résolus à
          l'évaluation. À changer avant le premier déploiement seulement.
        '';
      };
    };
  };

  config = lib.mkMerge (
    (lib.mapAttrsToList mkApp apps)
    ++ [
      (lib.mkIf anyEnabled {
        infra.servarr.mediaGroup.enable = true;
        users.groups.${mediaCfg.name}.gid = mediaCfg.gid;
      })

      # Passerelle qBittorrent : même hôte, même système de fichiers. Le
      # netns du kill switch n'isole que le réseau, les *arr lisent donc le
      # dossier de téléchargement directement.
      (lib.mkIf (anyEnabled && services.hasTag qbittorrentTag) {
        systemd.tmpfiles.settings.servarr.${qbittorrentDownloadDir}.d = {
          user = config.services.qbittorrent.user;
          group = mediaCfg.name;
          # setgid : tout ce que qBittorrent crée ici appartient au groupe
          # media, donc reste supprimable par les *arr après import.
          mode = "2775";
        };
        systemd.services.qbittorrent.serviceConfig.UMask = "0002";
      })
    ]
  );
}
