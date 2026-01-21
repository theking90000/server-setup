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
    
    enabledCollectors = [ "systemd" "processes" "textfile" ];
    
    # Collecter la sauvegarde Restic!
    extraFlags = [ "--collector.textfile.directory=/var/lib/node_exporter/textfile_collector" ];
  };
  
  # On s'assure que le dossier existe avec les bons droits
  systemd.tmpfiles.rules = [
    "d /var/lib/node_exporter/textfile_collector 0755 nobody nogroup"
  ];

  # LA SÉCURITÉ : On ouvre le port 9100 UNIQUEMENT sur l'interface wg0
  networking.firewall.interfaces.wg0.allowedTCPPorts = [ 9100 ];
}