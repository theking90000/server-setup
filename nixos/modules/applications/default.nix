# -------------------------------------------------------------------------
# applications/default.nix — Modules applicatifs
#
# Liste explicite des modules applicatifs disponibles.
# Chaque module s'active via un tag correspondant dans `infra.nodes`.
#
# Modules :
#   - docker-registry   : registre Docker privé (tag: applications/docker-registry)
#   - filesave           : serveur de partage de fichiers (tag: applications/filesave-server)
#   - gitea              : serveur Git auto-hébergé (tag: applications/gitea)
#   - jellyfin             : serveur multimédia (tag: applications/jellyfin)
#   - ntfy               : serveur de notifications push (tag: applications/ntfy)
#   - reposilite         : gestionnaire de dépôts Maven (tag: applications/reposilite)
#   - rust-storage-streamer : gateways Files et S3 sur Discord (tag: applications/rust-storage-streamer)
#   - sncb-insights      : scraping des données de la SNCB (tag: applications/sncb-insights)
#   - synapse            : homeserver Matrix fédéré (tag: applications/synapse)
#   - www                : serveur de fichiers statiques (tag: applications/www)
# -------------------------------------------------------------------------
{
  imports = [
    ./docker-registry.nix
    ./filesave.nix
    ./gitea.nix
    ./jellyfin.nix
    ./ntfy.nix
    ./reposilite.nix
    ./rust-storage-streamer.nix
    ./sncb-insights.nix
    ./synapse.nix
    ./www.nix
  ];
}
