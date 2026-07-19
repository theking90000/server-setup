# -------------------------------------------------------------------------
# ingress.nix — Abstraction ingress (reverse proxy HTTPS)
#
# Déclare l'option `infra.ingress`. Deux formes :
#
#   Forme simple — une URL et un backend :
#     infra.ingress.gitea = {
#       url = "https://git.example.com";
#       proxyTo = "http://10.100.0.2:3000";
#     };
#
#   Forme avancée — endpoint et routes :
#     infra.ingress.myapp = {
#       endpoint = { host = "app.example.com"; basePath = "/prefix"; };
#       routes.main = { path = "/"; proxyTo = "http://127.0.0.1:3000"; };
#       routes.metrics = { path = "/metrics"; nginx.return = "403"; };
#     };
#
# Le schéma du backend (`proxyTo`) porte le TLS amont : "https://…"
# active proxy_ssl_verify off vers le backend. Les URL publiques sont
# HTTPS uniquement — un ingress produit toujours son claim ACME.
# Les chemins de routes sont relatifs à `basePath`. Le sous-attribut
# `nginx` d'une route reprend le vocabulaire natif de
# `services.nginx.virtualHosts.*.locations.*` (return, extraConfig, …) ;
# les besoins avancés s'expriment ainsi, sans booléens génériques.
#
# La compilation en virtualHosts, claims ACME et upstreams est faite par
# nginx.nix sur les nœuds `web-server`.
# -------------------------------------------------------------------------
{ lib, ... }:

let
  types = lib.types;

  routeSubmodule = types.submodule {
    options = {
      path = lib.mkOption {
        type = types.str;
        default = "/";
        description = "Chemin de la route, relatif à endpoint.basePath.";
      };

      match = lib.mkOption {
        type = types.enum [
          "prefix"
          "exact"
        ];
        default = "prefix";
        description = "Mode de correspondance du chemin.";
      };

      proxyTo = lib.mkOption {
        type = types.nullOr (types.either types.str (types.listOf types.str));
        default = null;
        description = "Backend(s) de la route (ex: \"http://10.100.0.2:3000\"). Le schéma porte le TLS amont.";
      };

      forwardPath = lib.mkOption {
        type = types.enum [
          "preserve"
          "strip-prefix"
        ];
        default = "preserve";
        description = "Transmettre le chemin public tel quel, ou retirer le préfixe de la location.";
      };

      nginx = lib.mkOption {
        type = types.attrs;
        default = { };
        description = ''
          Fragment natif fusionné dans la location Nginx générée
          (vocabulaire de services.nginx.virtualHosts.*.locations.*).
          Fusion superficielle : une route appartient à un seul module.
        '';
      };
    };
  };

  ingressSubmodule = types.submodule (
    { config, ... }:
    let
      parsed = builtins.match "([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]+)(/[^?#]*)?" (toString config.url);
      parsedHost = builtins.elemAt parsed 1;
      parsedPath = builtins.elemAt parsed 2;
    in
    {
      options = {
        url = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "URL publique HTTPS (ex: https://app.example.com/prefix). Renseigne endpoint.host et endpoint.basePath.";
        };

        proxyTo = lib.mkOption {
          type = types.nullOr (types.either types.str (types.listOf types.str));
          default = null;
          description = "Backend(s) de la route racine (sucre pour routes.main).";
        };

        endpoint = {
          scheme = lib.mkOption {
            type = types.enum [ "https" ];
            default = "https";
            description = "Schéma public. HTTPS uniquement.";
          };

          host = lib.mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Hôte public. Un wildcard \"*.x.y\" n'accepte qu'un seul label, aligné sur le certificat.";
          };

          basePath = lib.mkOption {
            type = types.str;
            default = "/";
            description = "Préfixe public sous lequel les routes sont montées.";
          };
        };

        routes = lib.mkOption {
          type = types.attrsOf routeSubmodule;
          default = { };
          description = "Routes de l'endpoint, aux chemins relatifs à basePath.";
        };

        nginx.extraConfig = lib.mkOption {
          type = types.lines;
          default = "";
          description = "Fragment Nginx ajouté au niveau du virtualHost.";
        };
      };

      config = {
        endpoint.host = lib.mkIf (config.url != null && parsed != null) (lib.mkDefault parsedHost);
        endpoint.basePath = lib.mkIf (config.url != null && parsed != null && parsedPath != null) (
          lib.mkDefault parsedPath
        );
        routes.main = lib.mkIf (config.proxyTo != null) {
          path = lib.mkDefault "/";
          match = lib.mkDefault "prefix";
          proxyTo = lib.mkDefault config.proxyTo;
        };
      };
    }
  );
in
{
  options.infra.ingress = lib.mkOption {
    type = types.attrsOf ingressSubmodule;
    default = { };
    description = "Abstraction pour gérer les ingress HTTPS.";
  };
}
