{ lib, ... }:

let
  dir = ./.;
  entries = builtins.readDir dir;

  # Fonction utilitaire pour construire le chemin
  mkPath = name: dir + "/${name}";

  filter =
    name: type:
    let
      path = mkPath name;
      isNixFile = type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix";
      # On n'importe le dossier QUE s'il contient un default.nix (sinon error)
      isDirWithDefault = type == "directory" && builtins.pathExists (path + "/default.nix");
    in
    isNixFile || isDirWithDefault;

  validFiles = lib.filterAttrs filter entries;

  # Transformation en liste de chemins
  paths = map (name: mkPath name) (builtins.attrNames validFiles);
in
{
  imports = paths;
}
