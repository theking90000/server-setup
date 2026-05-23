# -------------------------------------------------------------------------
# rclone-sync.nix — Points de montage distants via Rclone
#
# Monte des systèmes de fichiers distants via rclone (S3, SFTP, WebDAV, etc.).
# Chaque entrée déclare le(s) noeud(s) cible (targetNodes) — le module
# s'active automatiquement si au moins un mount cible le noeud courant.
# Pas de tag requis.
#
# Les configs rclone (configContent) sont déployées comme secrets
# via Colmena dans /var/lib/secrets/rclone-sync/<mountName>/rclone.conf.
# Le token OAuth est extrait puis persisté hors secrets dans
# /var/lib/rclone-sync/<mountName>/token pour survivre aux redeploys.
# La couche crypt de rclone est supportée nativement en définissant
# deux remotes [backend] + [crypt] dans configContent.
#
# Pour chaque mount avec configContent, un service systemd rclone-token-<name>
# prépare le runtime config (secret sans token + token persistant) et sauvegarde
# le token rafraîchi au démontage.
#
# Options de performance avec des défauts agressifs :
#   - vfsCacheMode = "writes", cacheDir = /var/cache/rclone
#   - vfsCacheMaxSize = "5G", vfsCacheMaxAge = "1h"
#   - bufferSize = "16M", readAhead = "128M"
#
# Secrets : infra.rcloneSync.mounts.<name>.configContent (Colmena)
# -------------------------------------------------------------------------
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption mkIf mkMerge types;

  cfg = config.infra.rcloneSync;
  nodeName = config.infra.nodeName;

  mountedHere = lib.filterAttrs (_: m: builtins.elem nodeName m.targetNodes) cfg.mounts;
  hasMounts = mountedHere != { };

  # Escape un chemin de montage en nom d'unité systemd
  # "/mnt/backup-s3" → "mnt-backup\\x2ds3"
  escapeMountUnit = path:
    let
      stripped = lib.removePrefix "/" path;
      withDashes = builtins.replaceStrings [ "/" ] [ "-" ] stripped;
    in
    builtins.replaceStrings [ "-" ] [ "\\x2d" ] withDashes;

  # Options rclone (key=value) → converties en RCLONE_KEY via args2env
  mkRcloneOptions = mountName: mountCfg:
    let
      secretOpt =
        lib.optional (mountCfg.configContent != null)
          "config=/run/rclone-sync/${mountName}/rclone.conf";

      cacheOpts =
        lib.optional (mountCfg.vfsCacheMode != "off")
          "vfs-cache-mode=${mountCfg.vfsCacheMode}"
        ++ lib.optional (mountCfg.cacheDir != null)
          "cache-dir=${mountCfg.cacheDir}"
        ++ lib.optional (mountCfg.vfsCacheMaxSize != null)
          "vfs-cache-max-size=${mountCfg.vfsCacheMaxSize}"
        ++ lib.optional (mountCfg.vfsCacheMaxAge != null)
          "vfs-cache-max-age=${mountCfg.vfsCacheMaxAge}";

      perfOpts =
        lib.optional (mountCfg.bufferSize != null)
          "buffer-size=${mountCfg.bufferSize}"
        ++ lib.optional (mountCfg.readAhead != null)
          "vfs-read-ahead=${mountCfg.readAhead}";
    in
    secretOpt ++ cacheOpts ++ perfOpts ++ mountCfg.extraOptions;

  # ── Helpers pour construire les unités systemd ──

  mkMountEntry = mountName: mountCfg:
    let
      device = if mountCfg.remotePath == ""
        then "${mountCfg.remoteName}:"
        else "${mountCfg.remoteName}:${mountCfg.remotePath}";

      fuseFlags = [ "nodev" "nofail" "args2env" ]
        ++ lib.optional mountCfg.allowOther "allow_other"
        ++ lib.optional mountCfg.allowRoot "allow_root";

      rcloneOpts = mkRcloneOptions mountName mountCfg;
      allOptions = lib.concatStringsSep "," (fuseFlags ++ rcloneOpts);

      hasConfig = mountCfg.configContent != null;
    in
    {
      what = device;
      where = mountCfg.mountPoint;
      type = "rclone";
      options = allOptions;

      wantedBy = [ "remote-fs.target" ];
      before = [ "remote-fs.target" ];

      wants = [ "network-online.target" ] ++ mountCfg.wants;
      after = [ "network-online.target" ] ++ lib.optional hasConfig "rclone-token-${mountName}.service" ++ mountCfg.after;

      requires = lib.optional hasConfig "rclone-token-${mountName}.service";
      bindsTo = lib.optional hasConfig "rclone-token-${mountName}.service";
    };

  mkTokenService = mountName: mountCfg:
    let
      mountUnit = escapeMountUnit mountCfg.mountPoint;
      runtimeDir = "/run/rclone-sync/${mountName}";
      stateDir = "/var/lib/rclone-sync/${mountName}";
      secretPath = "/var/lib/secrets/rclone-sync/${mountName}/rclone.conf";
      tokenFile = "${stateDir}/token";
      runtimeConfig = "${runtimeDir}/rclone.conf";
    in
    {
      description = "Rclone token manager for ${mountName}";

      wantedBy = [ "remote-fs.target" ];
      partOf = [ "${mountUnit}.mount" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
      };

      script = ''
        mkdir -p ${runtimeDir} ${stateDir}

        if [ -f "${tokenFile}" ]; then
          # Merge: static config (sans la ligne token) + token persistant
          grep -v '^token ' "${secretPath}" > "${runtimeConfig}"
          cat "${tokenFile}" >> "${runtimeConfig}"
        else
          # Premier boot : utiliser le secret tel quel (contient le token initial)
          cp "${secretPath}" "${runtimeConfig}"
        fi
        chmod 0600 "${runtimeConfig}"
      '';

      postStop = ''
        if [ -f "${runtimeConfig}" ] && grep -q '^token ' "${runtimeConfig}" 2>/dev/null; then
          grep '^token ' "${runtimeConfig}" > "${tokenFile}.tmp" 2>/dev/null || true
          if [ -s "${tokenFile}.tmp" ]; then
            mv "${tokenFile}.tmp" "${tokenFile}"
          fi
        fi
      '';
    };
in
{
  options.infra.rcloneSync = {
    mounts = mkOption {
      type = types.attrsOf (types.submodule ({ ... }: {
        options = {
          mountPoint = mkOption {
            type = types.str;
            description = "Chemin de montage local (ex: /mnt/backup).";
            example = "/mnt/backup";
          };

          targetNodes = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Noeuds devant monter ce remote.";
            example = [ "vps1" "vps2" ];
          };

          remoteName = mkOption {
            type = types.str;
            description = "Nom du remote dans la config rclone (ex: s3-crypt).";
            example = "s3-crypt";
          };

          remotePath = mkOption {
            type = types.str;
            default = "";
            description = "Chemin dans le remote (par défaut: racine).";
            example = "backups";
          };

          configContent = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Configuration rclone (secret — déployé via Colmena). Contient le token OAuth initial pour le premier boot.";
          };

          vfsCacheMode = mkOption {
            type = types.enum [ "off" "minimal" "writes" "full" ];
            default = "writes";
            description = "Mode de cache VFS (--vfs-cache-mode). `full` pour accès en écriture + lecture locale.";
          };

          cacheDir = mkOption {
            type = types.nullOr types.str;
            default = "/var/cache/rclone";
            description = "Dossier de cache rclone. null = défaut rclone (~/.cache/rclone).";
          };

          vfsCacheMaxSize = mkOption {
            type = types.nullOr types.str;
            default = "5G";
            description = "Taille max du cache VFS (ex: 10G, 500M).";
          };

          vfsCacheMaxAge = mkOption {
            type = types.nullOr types.str;
            default = "1h";
            description = "Âge max du cache VFS (ex: 1h, 30m).";
          };

          bufferSize = mkOption {
            type = types.nullOr types.str;
            default = "16M";
            description = "Taille du buffer de lecture (--buffer-size).";
          };

          readAhead = mkOption {
            type = types.nullOr types.str;
            default = "128M";
            description = "Taille du VFS read-ahead (--vfs-read-ahead). Accélère les lectures séquentielles.";
          };

          allowOther = mkOption {
            type = types.bool;
            default = true;
            description = "Autoriser les autres utilisateurs à accéder au montage (FUSE allow_other).";
          };

          allowRoot = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Autoriser root à accéder au montage quand allow_other est actif.
              Par défaut, avec allow_other seul, root est exclu. Activer cette
              option pour permettre à root d'accéder au mount en plus des
              autres utilisateurs.
            '';
          };

          extraOptions = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Options rclone supplémentaires (format key=value, converties en RCLONE_KEY).";
          };

          wants = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Unités systemd que ce mount 'wants'.";
            example = [ "postgresql.service" ];
          };

          after = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Unités systemd après lesquelles ce mount démarre.";
            example = [ "wireguard-wg0.service" ];
          };
        };
      }));
      default = { };
      description = "Configuration des montages rclone. Chaque entrée = un point de montage.";
    };
  };

  config = mkIf hasMounts (mkMerge [

    # ═══ Secrets (deployment.keys) ═══
    {
      deployment.keys = lib.mkMerge (lib.mapAttrsToList (mountName: mountCfg:
        mkIf (mountCfg.configContent != null) {
          "rclone-${mountName}" = {
            text = mountCfg.configContent;
            name = "rclone.conf";
            destDir = "/var/lib/secrets/rclone-sync/${mountName}";
            user = "root";
            group = "root";
            permissions = "0400";
          };
        }
      ) mountedHere);
    }

    # ═══ Packages & FUSE ═══
    {
      environment.systemPackages = [ pkgs.rclone ];
      programs.fuse.userAllowOther =
        mkIf (lib.any (m: m.allowOther) (builtins.attrValues mountedHere)) true;
    }

    # ═══ Token services (un par mount avec configContent) ═══
    {
      systemd.services = lib.mkMerge (lib.mapAttrsToList (mountName: mountCfg:
        mkIf (mountCfg.configContent != null) {
          "rclone-token-${mountName}" = mkTokenService mountName mountCfg;
        }
      ) mountedHere);
    }

    # ═══ Systemd mount units (listOf) ═══
    {
      systemd.mounts = lib.mapAttrsToList mkMountEntry mountedHere;
    }

    # ═══ Création des dossiers de montage ═══
    {
      systemd.tmpfiles.rules = lib.mapAttrsToList (_: mountCfg:
        "d ${mountCfg.mountPoint} 0755 root root -"
      ) mountedHere;
    }

  ]);
}
