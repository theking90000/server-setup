{ config, pkgs, lib, ... }:

{
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    
    # CRITIQUE : On désactive l'ouverture automatique du firewall global
    openFirewall = false; 
    
    # On écoute sur toutes les interfaces (0.0.0.0) car c'est le firewall qui va trier,
    # ou on peut bind sur l'IP VPN si on veut être puriste (mais plus chiant à configurer).
    # listenAddress = "0.0.0.0"; 
    
    enabledCollectors = [ "systemd" "processes" ];
  };

  # LA SÉCURITÉ : On ouvre le port 9100 UNIQUEMENT sur l'interface wg0
  networking.firewall.interfaces.wg0.allowedTCPPorts = [ 9100 ];
}