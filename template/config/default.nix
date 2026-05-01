{
  imports = [
    ./acme/acme.nix
    ./docker-registry/docker-registry.nix
    ./filesave/filesave.nix
    ./gitea/gitea.nix
    ./grafana/grafana.nix
    ./ntfy/ntfy.nix
    ./reposilite/reposilite.nix
    ./restic/restic.nix
    ./www/www.nix
  ];
}
