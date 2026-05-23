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
# La couche crypt de rclone est supportée nativement en définissant
# deux remotes [backend] + [crypt] dans configContent.
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
  inherit (builtins) elem attrValues removeAttrs;

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

  mkRcloneOptions = mountName: mountCfg:
    let
      secretOpt =
        lib.optional (mountCfg.configContent != null)
          "config=/var/lib/secrets/rclone-sync/${mountName}/rclone.conf";

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
            description = "Configuration rclone (secret — déployé via Colmena).";
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
            description = "Autoriser les autres utilisateurs à accéder au montage (FUSE allow_other). Si désactivé, seul root peut y accéder.";
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
            description = "Options rclone supplémentaires (format key=value, converties en RCLONE_KEY via args2env).";
            example = [ "--dir-cache-time=10m" "vfs-read-chunk-size=64M" ];
          };

          wants = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Unités systemd que ce mount 'wants' (en plus de network-online.target).";
            example = [ "postgresql.service" ];
          };

          after = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Unités systemd après lesquelles ce mount démarre (en plus de network-online.target).";
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

    # ═══ Systemd mount units ═══
    {
      systemd.mounts = lib.mkMerge (lib.mapAttrsToList (mountName: mountCfg:
        let
          device = if mountCfg.remotePath == ""
            then "${mountCfg.remoteName}:"
            else "${mountCfg.remoteName}:${mountCfg.remotePath}";

          unitName = escapeMountUnit mountCfg.mountPoint;

          # FUSE flags passés directement (ne passent pas par args2env)
          fuseFlags = [ "nodev" "nofail" "args2env" ]
            ++ lib.optional mountCfg.allowOther "allow_other"
            ++ lib.optional mountCfg.allowRoot "allow_root";

          # Options rclone (key=value → RCLONE_KEY via args2env)
          rcloneOpts = mkRcloneOptions mountName mountCfg;

          allOptions = lib.concatStringsSep "," (fuseFlags ++ rcloneOpts);
        in
        {
          ${unitName} = {
            what = device;
            where = mountCfg.mountPoint;
            type = "rclone";
            options = allOptions;

            wantedBy = [ "remote-fs.target" ];
            before = [ "remote-fs.target" ];

            wants = [ "network-online.target" ] ++ mountCfg.wants;
            after = [ "network-online.target" ] ++ mountCfg.after;
          };
        }
      ) mountedHere);
    }

    # ═══ Création des dossiers de montage ═══
    {
      systemd.tmpfiles.rules = lib.mapAttrsToList (_: mountCfg:
        "d ${mountCfg.mountPoint} 0755 root root -"
      ) mountedHere;
    }

  ]);
}
