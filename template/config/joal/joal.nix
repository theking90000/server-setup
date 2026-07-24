{ ... }:
{
  infra.joal = {
    # URL publique optionnelle de la WebUI. Le nœud doit porter à la fois
    # applications/joal et applications/qbittorrent : toutes les annonces
    # passent obligatoirement par le VPN + kill switch qBittorrent.
    # Pour partager le vhost qBittorrent, utiliser par exemple
    # https://qbt.CHANGEME/joal et définir ui_path = "joal" dans
    # secrets/joal.json. L'interface sera https://qbt.CHANGEME/joal/ui/
    # et héritera du SSO oauth2-proxy du vhost qBittorrent.
    # url = "https://joal.CHANGEME";
  };
}
