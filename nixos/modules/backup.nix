{ config, pkgs, lib, ... }:

let
  cfg = config.profile.backup;
in
{
  options.profile.backup = {
    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Liste des chemins à sauvegarder, alimentée par les autres modules.";
    };
  };

    # 2. Restic : Le camion poubelle qui emporte tout
   config = {
   services.restic.backups."daily-s3" = {
      initialize = true; # Crée le repo s'il n'existe pas
      
      # Où on envoie ?
      repositoryFile = "/var/lib/secrets/restic-repo-url";
      # environmentFile = ... (Pour les clés AWS_ACCESS_KEY_ID si S3)

      passwordFile = "/var/lib/secrets/restic-password";
      environmentFile = "/var/lib/secrets/restic-s3-env";

      # Quoi sauvegarder ?
      paths = [
        "/var/backup"        
        "/home/ansible"
      ] ++ cfg.paths; # On ajoute les chemins fournis par les autres modules

      # On exclut les trucs lourds et inutiles
      exclude = [
        "/var/lib/docker"     # On ne sauvegarde pas le runtime docker, juste les volumes ou le registry
        "/var/log"
        "*.log"
      ];

      # Nettoyage automatique (Garder 7 jours, 4 semaines, 6 mois)
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 4"
        "--keep-monthly 6"
      ];

      # Timer : À 3h du matin (après le dump SQL de 2h)
      timerConfig = {
        OnCalendar = "03:00";
        Persistent = true;
      };
    };
   };
}