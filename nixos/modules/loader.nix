{ config, pkgs, ... }:

{
    imports = [
        ./wireguard.nix
        ./monitoring.nix
        ./profile.nix
    ];

}