# -------------------------------------------------------------------------
# nodes.nix — Infrastructure inventory & node identity
#
# Déclare les options fondamentales de l'infrastructure :
#   - infra.registeredTags   : liste auto-déclarée des tags connus (par les modules importés)
#   - infra.nodeName         : nom du noeud courant (défini par Colmena)
#   - infra.nodes            : inventaire complet des noeuds (topologie)
#
# Chaque noeud de l'inventaire possède les champs :
#   - publicIp, vpnIp, ipv6, ipv6_gateway
#   - user, sshKey           : pour le déploiement SSH
#   - wireguardPublicKey     : clé publique WireGuard (générée par scripts/generate-mesh.sh)
#   - sshPublicKey           : clé publique SSH pour root authorized_keys
#   - tags                   : liste des tags activés sur ce noeud
#
# Vérifie à l'évaluation que tous les tags utilisés sont bien déclarés
# par un module importé (via infra.registeredTags).
# -------------------------------------------------------------------------
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

            wireguardPublicKey = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Clé publique WireGuard du noeud. Générée par scripts/generate-mesh.sh.";
              example = "RepSHS/GGSefxJ+IbYxaPJd2XLqMFp+lfV8RAXP7fT0=";
            };

            sshPublicKey = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Clé publique SSH à ajouter aux authorized_keys de root.";
              example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...";
            };

            tags = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Liste des tags à appliquer sur ce noeud.";
            };

            publicInterface = lib.mkOption {
              type = lib.types.str;
              default = "ens3";
              description = "Nom de l'interface réseau publique (ex: ens3, eth0, enp0s3).";
            };

            useDHCP = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Utiliser DHCP sur l'interface publique. Désactiver pour une IP statique.";
            };

            timezone = lib.mkOption {
              type = lib.types.str;
              default = "Europe/Paris";
              description = "Fuseau horaire du noeud.";
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
          wireguardPublicKey = "RepSHS/GGSefxJ+IbYxaPJd2XLqMFp+lfV8RAXP7fT0=";
          sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...";
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
    ) config.infra.nodes
  );
}
