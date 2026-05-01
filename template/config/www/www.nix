# -------------------------------------------------------------------------
# www.nix — Hébergement web statique
#
# Sert un paquet Nix (site statique compilé) en contenu principal,
# avec un fallback vers /var/lib/www/public pour les gros fichiers
# gérés manuellement (zip, vidéos, images…).
#
# Les deux sources sont optionnelles :
#   - package   : paquet Nix servi à la racine (ex: site Hugo compilé)
#   - publicDir : dossier pour les fichiers lourds gérés hors Nix
#
# Usage minimum (juste un dossier de fichiers) :
#   { infra.www.url = "https://fichiers.example.com"; }
#
# Usage avec un site compilé :
#   { pkgs, ... }: {
#     infra.www = {
#       url = "https://mon-site.com";
#       package = pkgs.stdenv.mkDerivation {
#         name = "mon-site";
#         src = ./site-source;
#         installPhase = "mkdir -p $out && cp -r * $out/";
#       };
#     };
#   }
#
# Tags requis : `applications/www`
# -------------------------------------------------------------------------
{
  infra.www = {
    url = "https://CHANGEME";

    # Décommente pour servir un paquet Nix :
    # package = pkgs.callPackage ./mon-site.nix { };

    # Décommente pour changer le dossier public (défaut: /var/lib/www/public) :
    # publicDir = "/var/lib/www/public";

    # Décommente pour changer le port VPN (défaut: 8090) :
    # port = 8090;
  };
}
