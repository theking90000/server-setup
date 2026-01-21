# Hive.nix
#
# Ce fichier définit la configuration du "hive" pour Colmena.
# Par défaut, il inclut tous les nœuds définis dans le fichier topology.nix.
#
# Chaque noeud possède sa propre configuration dans le fichier nixos/node.nix

{ ... }:
{
  meta = {
    nixpkgs = import <nixpkgs> {
      system = "x86_64-linux";
    };
  };
}
// (
  let
    topo = import ./inventory/topology.nix;

    generateNode = name: data: import ./nixos/node.nix { inherit name data; };
  in
  builtins.mapAttrs generateNode topo.nodes
)
