{ lib, ... }:

let
  types = lib.types;

  # Définition de la structure de chaque "site"
  ingressSubmodule = types.submodule {
    options = {
      domain = lib.mkOption {
        type = types.str;
        description = "Le domaine public (ex: grafana.monsite.com)";
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
