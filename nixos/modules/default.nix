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
#   - lib/acme      : résolution pure des claims ACME vers les émetteurs
# -------------------------------------------------------------------------
{ lib, ... }:

{
  imports = [
    ../lib/services.nix
    ../lib/ops.nix
    ../lib/acme.nix
    ./nodes.nix
    ./base.nix

    ./applications
    ./backup
    ./monitoring
    ./network
    ./security
    ./web
  ];

  options.infra.sops.secretsDirectory = lib.mkOption {
    type = lib.types.path;
    description = "Dossier privé contenant les fichiers JSON chiffrés avec SOPS.";
  };

  config.sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
}
