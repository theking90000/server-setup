# -------------------------------------------------------------------------
# network.nix — Configuration réseau de base du noeud
#
# Configure le hostname, l'interface ens3 (DHCP IPv4 + IPv6 statique OVH),
# active nftables et le sysctl ip_nonlocal_bind pour le proxy transparent.
#
# Les paramètres sont lus depuis `infra.nodes.<nom>.{ipv6,ipv6_gateway}`.
# -------------------------------------------------------------------------
{ config, lib, ... }:

let
  nodeName = config.infra.nodeName;
  node = config.infra.nodes.${nodeName};
in
{
  networking = {
    hostName = nodeName;

    nftables.enable = true;

    interfaces.ens3 = {
      useDHCP = true;

      ipv6.addresses = lib.mkIf (node.ipv6 or null != null) [
        {
          address = node.ipv6;
          prefixLength = 128;
        }
      ];
    };

    defaultGateway6 = lib.mkIf (node.ipv6_gateway or null != null) {
      address = node.ipv6_gateway;
      interface = "ens3";
    };
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_nonlocal_bind" = 1;
    "net.ipv6.ip_nonlocal_bind" = 1;
  };
}
