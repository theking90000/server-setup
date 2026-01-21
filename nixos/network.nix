# network.nix
#
# Ce fichier définit la configuration réseau pour un nœud NixOS.
# Les paramètres réseau sont personnalisés selon les données fournies.
#

{ name, data }:
{
  networking = {

    # Utilisation de nftables pour la gestion des pare-feux
    nftables.enable = true;

    # Configuration de l'interface réseau ens3
    # (convention chez OVH pour les VPS)
    interfaces.ens3 = {

      # Utilisation du DHCP pour l'IPV4
      useDHCP = true;

      # Configuration de l'adresse IPv6 statique
      # en utilisant les informations OVH
      ipv6.addresses = [
        {
          address = data.ipv6;
          prefixLength = 128;
        }
      ];
    };

    # Configuration de la passerelle IPv6 par défaut
    # en utilisant les informations OVH
    defaultGateway6 = {
      address = data.ipv6_gateway;
      interface = "ens3";
    };
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_nonlocal_bind" = 1;
    "net.ipv6.ip_nonlocal_bind" = 1;
  };
}
