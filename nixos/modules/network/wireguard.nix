# -------------------------------------------------------------------------
# wireguard.nix — Mesh VPN WireGuard entre tous les noeuds
#
# Configure l'interface wg0 avec un maillage complet (full mesh) :
# chaque noeud est peer de tous les autres. La topologie est lue
# depuis `config.infra.nodes` fourni par le repo privé.
#
# La clé privée WireGuard est déployée par le repo privé via
# `deployment.keys."wg-key"` (Colmena). Ce module ne fait que
# référencer le fichier déployé.
#
# Nécessite que chaque noeud de `infra.nodes` ait :
#   - vpnIp               : IP virtuelle dans le mesh
#   - publicIp            : endpoint public
#   - wireguardPublicKey  : clé publique WireGuard
#
# Ouvre le port UDP 51820 et peuple /etc/hosts avec les IPs VPN.
# -------------------------------------------------------------------------
{ config, lib, ... }:

let
  nodeName = config.infra.nodeName;
  nodes = config.infra.nodes;

  me = nodes.${nodeName};

  peerNames = builtins.attrNames (builtins.removeAttrs nodes [ nodeName ]);
in
{
  networking.firewall.allowedUDPPorts = [ 51820 ];

  networking.wireguard.interfaces.wg0 = lib.mkIf (me.vpnIp != null) {
    ips = [ "${me.vpnIp}/24" ];
    listenPort = 51820;

    privateKeyFile = "/var/lib/secrets/wg-key";

    peers = map (peerName:
      let
        peer = nodes.${peerName};
      in
      {
        publicKey = peer.wireguardPublicKey;
        allowedIPs = [ "${peer.vpnIp}/32" ];
        endpoint = "${peer.publicIp}:51820";
        persistentKeepalive = 25;
      }
    ) peerNames;
  };

  networking.hosts = builtins.listToAttrs (
    map (n: {
      name = nodes.${n}.vpnIp;
      value = [ n ];
    }) (builtins.attrNames nodes)
  );
}
