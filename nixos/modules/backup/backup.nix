{ lib, ... }:
{
  options.infra.backup = {
    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Liste des chemins à sauvegarder.";
    };
  };
}
