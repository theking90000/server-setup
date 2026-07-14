# -------------------------------------------------------------------------
# network.nix — Configuration réseau de base du noeud
#
# Configure le hostname, l'interface publique (DHCP IPv4 + IPv6 statique),
# active nftables et le sysctl ip_nonlocal_bind pour le proxy transparent.
#
# L'interface publique est lue depuis `infra.nodes.<nom>.publicInterface`
# (par défaut "ens3" pour OVH). Les paramètres IPv6 sont lus depuis
# `infra.nodes.<nom>.{ipv6,ipv6Gateway}`.
# -------------------------------------------------------------------------
{ config, lib, ... }:

let
  nodeName = config.infra.nodeName;
  node = config.infra.nodes.${nodeName};
in
{
  time.timeZone = node.timezone or "Europe/Paris";

  networking = {
    hostName = nodeName;

    nftables.enable = true;

    interfaces.${node.publicInterface} = {
      useDHCP = node.useDHCP;

      ipv6.addresses = lib.mkIf (node.ipv6 or null != null) [
        {
          address = node.ipv6;
          prefixLength = 128;
        }
      ];
    };

    defaultGateway6 = lib.mkIf (node.ipv6Gateway or null != null) {
      address = node.ipv6Gateway;
      interface = node.publicInterface;
    };
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_nonlocal_bind" = 1;
    "net.ipv6.ip_nonlocal_bind" = 1;
  };
}
