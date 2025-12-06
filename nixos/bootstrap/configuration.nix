{ config, pkgs, ... }:

let
  # On importe les variables générées par Ansible
  vars = import ./ansible-vars.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ./loader.nix
  ];

  environment.systemPackages = with pkgs; [
    python3
    git
    vim
  ];

  # Configuration SSH via les variables importées
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = vars.adminKeys;

  # Configuration User Ansible
  security.sudo.enable = true;
  security.sudo.wheelNeedsPassword = false;

  users.users.ansible = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = vars.ansibleKeys;
  };

  # Networking
  networking.hostName = vars.hostName;
  networking.domain = "vps.ovh.net";

  # Nettoyage
  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;

  system.stateVersion = "23.11";

  # Réseau
  networking = {
    nftables.enable = true;

    interfaces.ens3 = {
      # 1. IPv4 : On reste en DHCP.
      # Pourquoi ? Car OVH gère ça très bien, et si vous changez d'offre, l'IP suivra sans casser la config.
      useDHCP = true;

      # 2. IPv6 : La partie manuelle obligatoire
      ipv6.addresses = [
        {
          address = vars.ipv6; # Votre IP du panel
          prefixLength = 128;
        }
      ];
    };

    # La passerelle IPv6 bizarre d'OVH (Le truc qui termine par des ff)
    # C'est l'adresse du routeur OVH, pas la vôtre.
    defaultGateway6 = {
      address = vars.ipv6_gateway;
      interface = "ens3";
    };
  };
}
