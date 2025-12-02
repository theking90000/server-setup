{ config, pkgs, ... }:

{
    imports = [
        ./wireguard.nix
        ./dns.nix
        ./monitoring.nix
        ./backup.nix

        # Profiles activables
        ./profiles/grafana.nix
        ./profiles/prometheus.nix

        # Configuration du serveur (hosts/<hostname>/profile.nix)
        ./profile.nix
    ];

}