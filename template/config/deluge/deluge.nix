{ ... }:
{
  infra.deluge = {
    url = "https://deluge.CHANGEME";
    dataDirectory = "/srv/deluge-media";
  };
  # Optional read-only access to host mounts and symlink targets.
  # infra.deluge.allowPaths = [ "/mnt/silly-media" ];
}
