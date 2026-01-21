# node.nix
#
# Ce fichier définit la configuration d'un nœud pour Colmena.
# Chaque nœud possède sa propre configuration, basée sur les paramètres passés.
#

{ name, data }:
{
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "23.11";

  # Configuration Colmena pour le déploiement
  deployment = {
    # Informations de connexion au nœud cible
    targetUser = data.user or "root";
    targetHost = data.publicIp;

    # Construction de la configuration sur la cible
    buildOnTarget = true;
  };

  imports = [
    # Import de la configuration hardware générée par nixos-infect
    (../.secrets + "/${name}/hardware.nix")

    # Configuration Réseau
    (import ./network.nix { inherit name data; })

    # Configuration SSH
    (import ./ssh.nix { inherit name data; })

    # Configuration Wireguard (réseau virtuel)
    (import ./wireguard.nix { inherit name; })

    #./.secrets/mesh.nix
  ];

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
}
