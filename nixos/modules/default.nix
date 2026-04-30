# -------------------------------------------------------------------------
# modules/default.nix — Point d'entrée de tous les modules
#
# Importé par le flake via `nixosModules.default`.
# Chaque sous-dossier contient un default.nix avec la liste explicite
# des modules qu'il regroupe.
#
# Arborescence :
#   - applications  : services applicatifs (docker-registry, gitea, ntfy, ...)
#   - backup        : sauvegardes (restic)
#   - monitoring    : observabilité (prometheus, grafana, node-exporter)
#   - network       : réseau, SSH, VPN WireGuard
#   - security      : pare-feu, certificats ACME
#   - web           : reverse proxy Nginx + ingress
#
# Bibliothèques :
#   - lib/services  : helpers hasTag, getVpnIpsByTag, getHostsByTag
#   - lib/ops       : mkSecretKeys (déploiement de secrets via Colmena)
# -------------------------------------------------------------------------
{
  imports = [
    ../lib/services.nix
    ../lib/ops.nix
    ./nodes.nix

    ./applications
    ./backup
    ./monitoring
    ./network
    ./security
    ./web
  ];
}
