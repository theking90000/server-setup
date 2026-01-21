{ lib, ... }:
rec {
  mkSecretKeys =
    prefix: secrets: filterList:
    let
      # If filterList is null, do not filter (keep all). Otherwise, filter by the list.
      filteredSecrets =
        if filterList == null then secrets else lib.filterAttrs (n: _: lib.elem n filterList) secrets;
    in
    lib.mapAttrs' (
      name: value:
      lib.nameValuePair "${prefix}-${name}" {
        # Le contenu du secret
        text = value;

        # Le nom du fichier final sur le disque (sans le préfixe dans le nom de fichier)
        # Ex: /var/lib/secrets/mon-app/db_pass
        name = name;

        # Le dossier parent
        destDir = "/var/lib/secrets/${prefix}";

        # Métadonnées standard
        user = "root";
        group = "root";
        permissions = "0400";
      }
    ) filteredSecrets;
}
