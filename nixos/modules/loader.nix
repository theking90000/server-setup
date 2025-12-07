{ config, pkgs, ... }:

{
  imports = [
    ./wireguard.nix
    ./dns.nix
    ./monitoring.nix
    ./backup.nix
    ./virtualisation.nix

    # Profiles activables
    ./profiles/grafana.nix
    ./profiles/prometheus.nix
    ./profiles/docker-registry.nix
    ./profiles/cert-issuer.nix
    ./profiles/cert-consumer.nix
    ./profiles/nginx.nix

    # Configuration du serveur (hosts/<hostname>/profile.nix)
    ./profile.nix
  ];

}
