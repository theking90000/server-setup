{
  infra.rcloneSync.mounts = {
    # Déclare uniquement le montage ici. Le fichier rclone contenant les
    # credentials est branché séparément dans secrets/default.nix.
    #
    # "backup-s3" = {
    #   mountPoint = "/mnt/backup";
    #   targetNodes = [ "CHANGEME" ];
    #   remoteName = "s3-crypt";
    #   remotePath = "backups";
    #   vfsCacheMode = "full";
    #   vfsCacheMaxSize = "10G";
    # };
  };
}
