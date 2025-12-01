{ config, pkgs, ... }:

{
    imports = [
        ./users.nix
        ./monitoring.nix
    ];

}