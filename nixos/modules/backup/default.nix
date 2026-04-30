# -------------------------------------------------------------------------
# backup/default.nix — Modules de sauvegarde
#
# Liste explicite des modules de sauvegarde.
# Chaque module s'active via un tag correspondant dans `infra.nodes`.
#
# Modules :
#   - backup          : déclare l'option `infra.backup.paths`
#   - restic          : backup Restic périodique (tag: backup)
#   - restic-restore  : script interactif de restauration (tag: backup)
# -------------------------------------------------------------------------
{
  imports = [
    ./backup.nix
    ./restic.nix
    ./restic-restore.nix
  ];
}
