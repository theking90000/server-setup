{ ... }:
{
  # Independent from infra.sonarr. Requires applications/deluge on the same node.
  infra.sonarrSilly.url = "https://sonarr-silly.CHANGEME";
  # Optional read-only access to host mounts and symlink targets.
  # infra.sonarrSilly.allowPaths = [ "/mnt/silly-media" ];
}
