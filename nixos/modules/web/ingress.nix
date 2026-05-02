# -------------------------------------------------------------------------
# ingress.nix — Abstraction ingress (reverse proxy)
#
# Déclare l'option `infra.ingress` : chaque entrée peut définir une URL
# complète (https://exemple.com/app) ou un domaine (+ chemin optionnel).
# L'URL est prioritaire : le module nginx parse automatiquement le domaine
# et le chemin à partir de l'URL.
#
# Support multi-domaine par chemins : plusieurs entrées peuvent partager
# le même domaine en spécifiant des chemins différents.
# -------------------------------------------------------------------------
{ lib, ... }:

let
  types = lib.types;

  ingressSubmodule = types.submodule {
    options = {
      url = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          URL publique complète (ex: https://exemple.com/app).
          Prioritaire sur domain+path : le domaine et le chemin sont extraits automatiquement.
        '';
      };

      domain = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Domaine public (ex: exemple.com). Ignoré si url est défini.";
      };

      path = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Chemin sous le domaine (ex: /app). null = racine /. Ignoré si url est défini.";
      };

      backend = lib.mkOption {
        type = types.listOf types.str;
        description = "La liste des IPs:ports du backend (ex: ['127.0.0.1:3000'])";
      };

      sslCertificate = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Certificat SSL à utiliser (optionnel, ACME est activé par défaut)";
      };

      blockPaths = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Liste de chemins à bloquer (ex: ['/admin', '/metrics'])";
      };

      backendTls = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Utiliser HTTPS pour la connexion aux backends (proxy_ssl_verify off).";
      };
    };
  };

in
{
  options.infra.ingress = lib.mkOption {
    type = types.attrsOf ingressSubmodule;
    default = { };
    description = "Abstraction pour gérer les ingress (HTTPS).";
  };
}
