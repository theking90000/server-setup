{ ... }:
{
  infra.qbittorrent = {
    # URL publique de la WebUI via nginx ; laisser commenté pour un accès
    # uniquement via le mesh WireGuard (tunnel SSH ou noeud web-server).
    # url = "https://CHANGEME";

    # Port BitTorrent forwardé par le provider VPN (statique uniquement,
    # ex: AirVPN). Laisser commenté si le forwarding est dynamique (Proton).
    # torrentingPort = 62000;
  };
}
