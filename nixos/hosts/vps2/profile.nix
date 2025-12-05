{ ... }:
{
  # Rien sur le VPS2 pour l'instant

  profile.certs = {
    syncDomains = [ "*.theking90000.be" ];
    masterIp = "vps1";
  };

  profile.nginx.enable = true;

  services.nginx.virtualHosts."grafana.theking90000.be" = {
    # C'est ici que votre macro travaille
    # Elle va chercher automatiquement dans /var/lib/ssl-sync/*.theking90000.be/
    profile.useHTTPS = true;
    profile.certName = "*.theking90000.be";

    # Si le nom du dossier de certif n'est pas le wildcard par défaut :
    # my-infra.certName = "le-nom-du-dossier-sync";

    locations."/" = {
      proxyPass = "http://vps1:3000";

      # INDISPENSABLE pour Grafana (les graphiques en temps réel utilisent des WebSockets)
      proxyWebsockets = true;

      # Headers de base pour que Grafana ne soit pas perdu
      extraConfig = ''
        proxy_set_header Host $host;
      '';
    };
  };
}
