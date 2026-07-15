{
  imports = [
    ./common.nix
    ./wireguard.nix
    ./acme.nix
    ./docker-registry.nix
    ./grafana.nix
    ./kanidm.nix
    ./restic.nix
    ./rclone-sync.nix
  ];
}
