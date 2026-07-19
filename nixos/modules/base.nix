# -------------------------------------------------------------------------
# base.nix — Utilitaires CLI présents sur tous les noeuds
#
# Paquets installés dans le profil système (donc dans le $PATH de tous les
# users, root inclus), sans tag ni condition. Réserver aux outils génériques
# de diagnostic/admin. Un outil propre à un rôle va dans son module gardé
# par tag.
# -------------------------------------------------------------------------
{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    htop
    ncdu
    jq
    dnsutils # dig, nslookup
    tree
  ];

  # Journal systemd : plafond 2G + purge des entrées de plus de 3 mois
  # (défaut = 4 GiB sans limite d'âge). Le premier seuil atteint gagne.
  services.journald.extraConfig = ''
    SystemMaxUse=2G
    MaxRetentionSec=3month
  '';
}
