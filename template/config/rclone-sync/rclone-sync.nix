{ ... }:
{
  infra.rcloneSync.mounts = {
    # ── Exemple: monter un bucket S3 chiffré avec rclone crypt ──
    # "backup-s3" = {
    #   mountPoint = "/mnt/backup";
    #   targetNodes = [ "CHANGEME" ];
    #   remoteName = "s3-crypt";
    #   remotePath = "backups";
    #
    #   # Performance — les défauts ci-dessous sont déjà ceux du module,
    #   # tu peux les omettre ou les ajuster.
    #   vfsCacheMode = "full";
    #   vfsCacheMaxSize = "10G";
    #   vfsCacheMaxAge = "2h";
    #   bufferSize = "32M";
    #   readAhead = "256M";
    #
    #   configContent = ''
    #     [s3-backend]
    #     type = s3
    #     provider = AWS
    #     env_auth = true
    #     region = us-east-1
    #
    #     [s3-crypt]
    #     type = crypt
    #     remote = s3-backend:mon-bucket
    #     password = CHANGEME
    #     password2 = CHANGEME
    #   '';
    # };

    # ── Exemple: monter un SFTP distant ──
    # "media-sftp" = {
    #   mountPoint = "/mnt/media";
    #   targetNodes = [ "CHANGEME" ];
    #   remoteName = "sftp-media";
    #   remotePath = "/exports/media";
    #   allowOther = false;
    #
    #   configContent = ''
    #     [sftp-media]
    #     type = sftp
    #     host = 192.168.1.50
    #     user = media
    #     key_file = /root/.ssh/id_ed25519
    #   '';
    # };
  };
}
