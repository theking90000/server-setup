# node.nix
#
# Ce fichier définit la configuration d'un nœud pour Colmena.
# Chaque nœud possède sa propre configuration, basée sur les paramètres passés.
#

{
  name,
  data,
}:

{
  lib,
  pkgs,
  config,
  ...
}:
let
  servicesMap = import ../inventory/services.nix;
  topology = import ../inventory/topology.nix;

  services = import ./lib/services.nix {
    inherit lib;
    nodes = topology.nodes;
    services = servicesMap;
    name = name;
  };

  ops = import ./lib/ops.nix { inherit lib; };
in
{
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "25.11";

  # Configuration Colmena pour le déploiement
  deployment = {
    # Informations de connexion au nœud cible
    targetUser = data.user or "root";
    targetHost = data.publicIp;

    # Construction de la configuration sur la cible
    buildOnTarget = true;

    tags = servicesMap."${name}" or [ ];
  };

  # Injecter les arguments dans les tous les lambdas "importés"
  _module.args = {
    inherit
      services
      name
      data
      ops
      ;
  };

  imports = [
    # Import de la configuration hardware générée par nixos-infect
    (../.secrets + "/${name}/hardware.nix")

    # Discovery des modules
    (./modules)
  ];

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
}
