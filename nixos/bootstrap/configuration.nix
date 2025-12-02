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
}