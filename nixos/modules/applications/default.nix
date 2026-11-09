# -------------------------------------------------------------------------
# applications/default.nix — Modules applicatifs
#
# Liste explicite des modules applicatifs disponibles.
# Chaque module s'active via un tag correspondant dans `infra.nodes`.
#
# Modules :
#   - docker-registry   : registre Docker privé (tag: applications/docker-registry)
#   - deluge            : client BitTorrent dans le VPN qBittorrent (tag: applications/deluge)
#   - filesave           : serveur de partage de fichiers (tag: applications/filesave-server)
#   - gitea              : serveur Git auto-hébergé (tag: applications/gitea)
#   - jellyfin             : serveur multimédia (tag: applications/jellyfin)
#   - joal               : client d'annonce dans le netns qBittorrent (tag: applications/joal)
#   - ntfy               : serveur de notifications push (tag: applications/ntfy)
#   - qbittorrent-silly  : instance indépendante dans le VPN partagé (tag: applications/qbittorrent-silly)
#   - qbittorrent        : client BitTorrent isolé derrière un VPN tiers (tag: applications/qbittorrent)
#   - reposilite         : gestionnaire de dépôts Maven (tag: applications/reposilite)
#   - rust-storage-streamer : gateways Files et S3 sur Discord (tag: applications/rust-storage-streamer)
#   - servarr            : Radarr et Sonarr (tags: applications/radarr, applications/sonarr)
#   - servarr-silly     : instances Sonarr/Radarr/Prowlarr séparées dans le VPN (tags: applications/{sonarr,radarr,prowlarr}-silly)
#   - sncb-insights      : scraping des données de la SNCB (tag: applications/sncb-insights)
#   - synapse            : homeserver Matrix fédéré (tag: applications/synapse)
#   - transmission-silly : client BitTorrent silly dans le VPN partagé (tag: applications/transmission-silly)
#   - www                : serveur de fichiers statiques (tag: applications/www)
# -------------------------------------------------------------------------
{
  imports = [
    ./docker-registry.nix
    ./deluge.nix
    ./filesave.nix
    ./gitea.nix
    ./jellyfin.nix
    ./joal.nix
    ./ntfy.nix
    ./qbittorrent-silly.nix
    ./qbittorrent.nix
    ./reposilite.nix
    ./rust-storage-streamer.nix
    ./servarr.nix
    ./servarr-silly.nix
    ./sncb-insights.nix
    ./synapse.nix
    ./transmission-silly.nix
    ./www.nix
  ];
}
