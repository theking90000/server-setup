{ config, pkgs, lib, ... }:

let
  wgConfig = import ./wg-peers.nix;
in
{
  # On transforme notre Attribute Set { vps1 = "10.x"; } en config /etc/hosts
  # networking.hosts attend format : { "10.0.0.1" = [ "vps1" ]; }
  
  networking.hosts = lib.mapAttrs' (name: ip: {
    name = ip;          # La clé devient l'IP
    value = [ name ];   # La valeur devient une liste contenant le nom
  }) wgConfig.ips;
}