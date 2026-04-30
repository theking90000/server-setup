# -------------------------------------------------------------------------
# services.nix — Helpers de découverte de services par tag
#
# Injecte `services` dans _module.args, fournissant les fonctions :
#   - hasTag tag           : vrai si le noeud courant possède le tag
#   - getHostsByTag tag    : liste des hostnames taggés
#   - getVpnIpsByTag tag   : IPs VPN de tous les noeuds taggés
#   - getVpnIp             : IP VPN du noeud courant
#
# Permet aux modules de s'interconnecter automatiquement sans
# configuration manuelle des adresses IP.
# -------------------------------------------------------------------------
{ config, lib, ... }:
let
  cfg = config.infra;
  me = cfg.nodes.${cfg.nodeName};
in
{
  _module.args.services = rec {
    hasTag = tag: lib.elem tag (me.tags or [ ]);

    getHostsByTag =
      tag: lib.attrNames (lib.filterAttrs (_: node: lib.elem tag (node.tags or [ ])) cfg.nodes);

    getVpnIpsByTag = tag: map (h: cfg.nodes.${h}.vpnIp) (getHostsByTag tag);

    getVpnIp = me.vpnIp;
  };
}
