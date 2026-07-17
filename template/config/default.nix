{
  imports = [
    ./acme/acme.nix
    ./docker-registry/docker-registry.nix
    ./filesave/filesave.nix
    ./gitea/gitea.nix
    ./grafana/grafana.nix
    ./jellyfin/jellyfin.nix
    ./kanidm/kanidm.nix
    ./ntfy/ntfy.nix
    ./rclone-sync/rclone-sync.nix
    ./reposilite/reposilite.nix
    ./rust-storage-streamer/rust-storage-streamer.nix
    ./synapse/synapse.nix
    ./www/www.nix
  ];
}
