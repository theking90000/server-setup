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
#   - ntfy               : serveur de notifications push (tag: applications/ntfy)
#   - reposilite         : gestionnaire de dépôts Maven (tag: applications/reposilite)
# -------------------------------------------------------------------------
{
  imports = [
    ./docker-registry.nix
    ./filesave.nix
    ./gitea.nix
    ./ntfy.nix
    ./reposilite.nix
  ];
}
