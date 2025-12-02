{ config, pkgs, lib, ... }:

let  
  # On importe la liste des copains générée par Ansible
  wg = import ../wg-peers.nix;
in
{
  networking.firewall.allowedUDPPorts = [ 51820 ];

  networking.wireguard.interfaces.wg0 = {
    ips = [ "${wg.wgIp}/24" ];
    listenPort = 51820;

    # LE POINT CRUCIAL DE SÉCURITÉ :
    # On ne met pas la clé en string ici. On donne le chemin du fichier.
    # Ainsi, la clé ne se retrouve pas dans le /nix/store mondialement lisible.
    privateKeyFile = "/var/lib/secrets/wg-private";

    peers = wg.peers;
  };
}