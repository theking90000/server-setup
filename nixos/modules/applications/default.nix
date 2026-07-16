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
    ./sncb-insights.nix
    ./synapse.nix
    ./www.nix
  ];
}
