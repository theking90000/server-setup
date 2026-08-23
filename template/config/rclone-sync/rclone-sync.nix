{
  infra.rcloneSync.mounts = {
    # Déclare uniquement le montage ici. Le fichier rclone contenant les
    # credentials est créé dans secrets/rclone-sync.json par init-project.
    #
    # "backup-s3" = {
    #   mountPoint = "/mnt/backup";
    #   targetNodes = [ "CHANGEME" ];
    #   remoteName = "s3-crypt";
    #   remotePath = "backups";
    #   vfsCacheMode = "full";
    #   vfsCacheMaxSize = "10G";
    # };
    #
    # Médiathèque écrite par Radarr/Sonarr : un montage FUSE présente des
    # propriétaires fixes, il faut donc les aligner sur le groupe partagé
    # `media` créé par le module servarr. Le `lib.optionals` évite de poser
    # un GID qui n'existerait pas sur un nœud sans Radarr ni Sonarr. Ce
    # fichier doit alors commencer par `{ config, lib, ... }:` :
    #
    # "media-gcrypt" = {
    #   mountPoint = "/mnt/media";
    #   targetNodes = [ "CHANGEME" ];
    #   remoteName = "gcrypt";
    #   remotePath = "MediaLibraries";
    #   allowOther = true;
    #   extraOptions = lib.optionals config.infra.servarr.mediaGroup.enable [
    #     "umask=002"
    #     "gid=${toString config.infra.servarr.mediaGroup.gid}"
    #   ];
    # };
  };
}
