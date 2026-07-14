# -------------------------------------------------------------------------
# sso.nix — Registre interne des clients SSO déclarés par les applications
#
# Les applications contribuent à infra.sso.<name>. Kanidm consomme ensuite ce
# registre. Les comptes et appartenances aux groupes restent gérés dans Kanidm.
# -------------------------------------------------------------------------
{ lib, ... }:

{
  options.infra.sso = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            displayName = lib.mkOption {
              type = lib.types.str;
              description = "Nom affiché du client SSO.";
            };

            serviceTag = lib.mkOption {
              type = lib.types.str;
              description = "Tag des nœuds qui exécutent l'application.";
            };

            redirectUris = lib.mkOption {
              type = lib.types.nonEmptyListOf lib.types.str;
              description = "URI de retour OAuth2 acceptées par l'application.";
            };

            landingUrl = lib.mkOption {
              type = lib.types.str;
              description = "URL d'accueil affichée dans Kanidm.";
            };

            secretFile = lib.mkOption {
              type = lib.types.str;
              default = "/run/secrets/sso/${name}-client-secret";
              description = "Chemin runtime partagé du secret OAuth2.";
            };

            scopes = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [
                "openid"
                "profile"
                "email"
              ];
              description = "Scopes accordés aux membres d'un groupe de ce client.";
            };

            public = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Déclarer un client public sans secret OAuth2.";
            };

            pkce = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Exiger PKCE pour ce client.";
            };

            enableLegacyCrypto = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Autoriser les algorithmes OAuth2 historiques pour ce client.";
            };

            preferShortUsername = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Utiliser le nom court Kanidm comme preferred_username.";
            };

            groups = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    extraScopes = lib.mkOption {
                      type = lib.types.listOf lib.types.str;
                      default = [ ];
                      description = "Scopes supplémentaires accordés à ce groupe.";
                    };

                    claims = lib.mkOption {
                      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
                      default = { };
                      description = "Claims OAuth2 produits pour ce groupe.";
                    };
                  };
                }
              );
              default = { };
              description = "Groupes de permissions définis par l'application.";
            };
          };
        }
      )
    );
    default = { };
    description = "Clients SSO auto-enregistrés par les modules applicatifs.";
  };
}
