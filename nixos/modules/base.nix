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
}
