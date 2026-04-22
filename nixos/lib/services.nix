{ config, lib, ... }:
let
  cfg = config.infra;
  me = cfg.nodes.${cfg.nodeName};
in
{
  _module.args.services = rec {
    # Vérifie si le noeud courant a un tag
    hasTag = tag: lib.elem tag (me.tags or [ ]);

    # Récupère la liste des hostnames qui possèdent un tag précis
    getHostsByTag =
      tag: lib.attrNames (lib.filterAttrs (_: node: lib.elem tag (node.tags or [ ])) cfg.nodes);

    # La "Killer Feature" : IPs VPN de tous les noeuds ayant un tag
    getVpnIpsByTag = tag: map (h: cfg.nodes.${h}.vpnIp) (getHostsByTag tag);

    # IP VPN du noeud courant
    getVpnIp = me.vpnIp;
  };
}
