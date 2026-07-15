# -------------------------------------------------------------------------
# rclone-sync.nix — Points de montage distants via Rclone
#
# Monte des systèmes de fichiers distants via rclone (S3, SFTP, WebDAV, etc.).
# Chaque entrée déclare le(s) noeud(s) cible (targetNodes) — le module
# s'active automatiquement si au moins un mount cible le noeud courant.
# Pas de tag requis.
#
# Les configs rclone sont amorcées depuis configContent/configFile vers
# /var/lib/rclone-sync/<mountName>/rclone.conf. Cette copie persistante et
# writable est ensuite entièrement gérée par rclone, notamment pour les
# rafraîchissements OAuth. La couche crypt fonctionne donc sans traitement
# spécial des lignes token. Pour réamorcer volontairement la configuration,
# arrêter le montage puis supprimer sa copie persistante.
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
  inherit (lib)
    mkOption
    mkIf
    mkMerge
    types
    ;

  cfg = config.infra.rcloneSync;
  nodeName = config.infra.nodeName;

  effectiveMounts = lib.mapAttrs (
    name: mount:
    mount
    // {
      configFile =
        if mount.configFile != null then
          mount.configFile
        else if mount.configContent != null then
          null
        else
          cfg.runtimeConfigFiles.${name} or "/run/secrets/rclone/${name}";
    }
  ) cfg.mounts;

  mountedHere = lib.filterAttrs (_: m: builtins.elem nodeName m.targetNodes) effectiveMounts;
  sopsMountsHere = lib.filterAttrs (
    name: mount:
    builtins.elem nodeName mount.targetNodes
    && mount.configContent == null
    && mount.configFile == null
    && !(builtins.hasAttr name cfg.runtimeConfigFiles)
  ) cfg.mounts;
  hasMounts = mountedHere != { };

  # Options rclone (key=value) → converties en RCLONE_KEY via args2env
  mkRcloneOptions =
    mountName: mountCfg:
    let
      secretOpt = lib.optional (
        mountCfg.configContent != null || mountCfg.configFile != null
      ) "config=/var/lib/rclone-sync/${mountName}/rclone.conf";

      cacheOpts =
        lib.optional (mountCfg.vfsCacheMode != "off") "vfs-cache-mode=${mountCfg.vfsCacheMode}"
        ++ lib.optional (mountCfg.cacheDir != null) "cache-dir=${mountCfg.cacheDir}"
        ++ lib.optional (mountCfg.vfsCacheMaxSize != null) "vfs-cache-max-size=${mountCfg.vfsCacheMaxSize}"
        ++ lib.optional (mountCfg.vfsCacheMaxAge != null) "vfs-cache-max-age=${mountCfg.vfsCacheMaxAge}";

      perfOpts =
        lib.optional (mountCfg.bufferSize != null) "buffer-size=${mountCfg.bufferSize}"
        ++ lib.optional (mountCfg.readAhead != null) "vfs-read-ahead=${mountCfg.readAhead}";
    in
    secretOpt ++ cacheOpts ++ perfOpts ++ mountCfg.extraOptions;

  # ── Helpers pour construire les unités systemd ──

  mkMountEntry =
    mountName: mountCfg:
    let
      device =
        if mountCfg.remotePath == "" then
          "${mountCfg.remoteName}:"
        else
          "${mountCfg.remoteName}:${mountCfg.remotePath}";

      fuseFlags = [
        "nodev"
        "nofail"
        "args2env"
      ]
      ++ lib.optional mountCfg.allowOther "allow_other"
      ++ lib.optional mountCfg.allowRoot "allow_root";

      rcloneOpts = mkRcloneOptions mountName mountCfg;
      allOptions = lib.concatStringsSep "," (fuseFlags ++ rcloneOpts);

      hasConfig = mountCfg.configContent != null || mountCfg.configFile != null;
    in
    {
      what = device;
      where = mountCfg.mountPoint;
      type = "rclone";
      options = allOptions;

      wantedBy = [ "remote-fs.target" ];
      before = [ "remote-fs.target" ];

      wants = [ "network-online.target" ] ++ mountCfg.wants;
      after = [
        "network-online.target"
      ]
      ++ lib.optional hasConfig "rclone-config-${mountName}.service"
      ++ mountCfg.after;

      requires = lib.optional hasConfig "rclone-config-${mountName}.service";
      bindsTo = lib.optional hasConfig "rclone-config-${mountName}.service";
    };

  mkConfigService =
    mountName: mountCfg:
    let
      stateDir = "/var/lib/rclone-sync/${mountName}";
      secretPath =
        if mountCfg.configFile != null then
          mountCfg.configFile
        else
          "/var/lib/secrets/rclone-sync/${mountName}/rclone.conf";
      persistentConfig = "${stateDir}/rclone.conf";
    in
    {
      description = "Initialize persistent Rclone config for ${mountName}";

      wantedBy = [ "remote-fs.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
        StateDirectory = "rclone-sync/${mountName}";
        StateDirectoryMode = "0700";
        UMask = "0077";
      };

      script = ''
        # ponytail: seed once; rclone owns every later token refresh.
        if [ ! -s "${persistentConfig}" ]; then
          ${pkgs.coreutils}/bin/install -m 0600 "${secretPath}" "${persistentConfig}"
        fi
        ${pkgs.coreutils}/bin/chmod 0600 "${persistentConfig}"
      '';
    };
in
{
  options.infra.rcloneSync = {
    runtimeConfigFiles = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Chemins runtime alternatifs, indexés par nom de montage.";
    };

    mounts = mkOption {
      type = types.attrsOf (
        types.submodule (
          { ... }: {
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
                example = [
                  "vps1"
                  "vps2"
                ];
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
                description = "Configuration rclone complète, déployée via Colmena et utilisée uniquement pour amorcer la copie persistante absente.";
              };

              configFile = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Chemin runtime d'une configuration rclone complète utilisée uniquement pour amorcer la copie persistante absente, par exemple un secret sops-nix.";
              };

              vfsCacheMode = mkOption {
                type = types.enum [
                  "off"
                  "minimal"
                  "writes"
                  "full"
                ];
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
          }
        )
      );
      default = { };
      description = "Configuration des montages rclone. Chaque entrée = un point de montage.";
    };
  };

  config = mkIf hasMounts (mkMerge [

    {
      assertions = lib.mapAttrsToList (mountName: mountCfg: {
        assertion = mountCfg.configContent == null || mountCfg.configFile == null;
        message = "Rclone mount ${mountName}: set at most one of configContent or configFile.";
      }) mountedHere;
    }

    {
      sops.secrets = lib.mapAttrs' (
        name: _:
        lib.nameValuePair "rclone/${name}" {
          sopsFile = config.infra.sops.secretsDirectory + "/rclone-sync.json";
          key = name;
        }
      ) sopsMountsHere;
    }

    # ═══ Secrets (deployment.keys) ═══
    {
      deployment.keys = lib.mkMerge (
        lib.mapAttrsToList (
          mountName: mountCfg:
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
        ) mountedHere
      );
    }

    # ═══ Packages & FUSE ═══
    {
      environment.systemPackages = [ pkgs.rclone ];
      programs.fuse.userAllowOther = mkIf (lib.any (m: m.allowOther) (
        builtins.attrValues mountedHere
      )) true;
    }

    # ═══ Initialisation persistante de la config (un service par mount) ═══
    {
      systemd.services = lib.mkMerge (
        lib.mapAttrsToList (
          mountName: mountCfg:
          mkIf (mountCfg.configContent != null || mountCfg.configFile != null) {
            "rclone-config-${mountName}" = mkConfigService mountName mountCfg;
          }
        ) mountedHere
      );
    }

    # ═══ Systemd mount units (listOf) ═══
    {
      systemd.mounts = lib.mapAttrsToList mkMountEntry mountedHere;
    }

    # ═══ Création des dossiers de montage ═══
    {
      systemd.tmpfiles.rules = lib.mapAttrsToList (
        _: mountCfg: "d ${mountCfg.mountPoint} 0755 root root -"
      ) mountedHere;
    }

  ]);
}
