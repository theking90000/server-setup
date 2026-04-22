{ lib, config, ... }:
{
  options.infra.registeredTags = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Liste de tous les tags gérés par l'infrastructure. Utile pour faire du reporting et des vérifications de cohérence. Auto-déclarées par les modules importés.";
  };

  options.infra.nodeName = lib.mkOption {
    type = lib.types.str;
    description = "Nom du noeud actuellement évalué. Utilisé par colmena.";
    default = "";
  };

  options.infra.nodes = lib.mkOption {
    description = "Inventaire des noeuds de l'infrastructure.";

    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            publicIp = lib.mkOption {
              type = lib.types.str;
              description = "Adresse IPv4 publique du noeud.";
              example = "38.10.12.23";
            };

            vpnIp = lib.mkOption {
              type = lib.types.str;
              description = "Adresse IP du noeud sur le mesh WireGuard.";
              example = "10.100.0.1";
            };

            ipv6 = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Adresse IPv6 publique du noeud.";
              example = "2001:3130:3132:2100::a38c";
            };

            ipv6_gateway = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Passerelle IPv6 du noeud.";
              example = "2001:3130:3132:2100::1";
            };

            user = lib.mkOption {
              type = lib.types.str;
              default = "root";
              description = "Utilisateur SSH pour le déploiement.";
            };

            sshKey = lib.mkOption {
              type = lib.types.str;
              default = "~/.ssh/id_ed25519";
              description = "Chemin de la clé SSH privée utilisée pour se connecter.";
            };

            tags = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Liste des tags à appliquer sur ce noeud.";
            };
          };
        }
      )
    );

    default = { };

    example = lib.literalExpression ''
      {
        vps1 = {
          publicIp = "38.10.12.23";
          vpnIp = "10.100.0.1";
          ipv6 = "2001:3130:3132:2100::a38c";
          ipv6_gateway = "2001:3130:3132:2100::1";
        };
      }
    '';
  };

  config.assertions = lib.flatten (
    lib.mapAttrsToList (
      nodeName: node:
      map (tag: {
        assertion = builtins.elem tag config.infra.registeredTags;
        message = ''
          Node "${nodeName}": tag "${tag}" is not handled by any module.
          Known tags: ${lib.concatStringsSep ", " (lib.unique config.infra.registeredTags)}.
          Maybe a typo?
        '';
      }) node.tags
    ) config.infra.topology.nodes
  );
}
