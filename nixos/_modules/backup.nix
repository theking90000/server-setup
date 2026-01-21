{
  config,
  pkgs,
  lib,
  ...
}:

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
      ]
      ++ cfg.paths; # On ajoute les chemins fournis par les autres modules

      # On exclut les trucs lourds et inutiles
      exclude = [
        "/var/lib/docker" # On ne sauvegarde pas le runtime docker, juste les volumes ou le registry
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

    ## Metrics : On expose les métriques pour Prometheus Node Exporter

    # 1. Le script qui génère les métriques
    systemd.services.restic-stats = {
      description = "Générer les métriques Prometheus pour Restic";

      # On charge les mêmes secrets que le backup
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        EnvironmentFile = "/var/lib/secrets/restic-s3-env";
      };

      path = [
        pkgs.restic
        pkgs.jq
        pkgs.moreutils
      ]; # moreutils pour 'sponge' ou juste redirection

      script = ''
        # Fichier de sortie
        PROM_FILE="/var/lib/node_exporter/textfile_collector/restic.prom"

        export RESTIC_REPOSITORY=$(cat /var/lib/secrets/restic-repo-url)
        export RESTIC_PASSWORD=$(cat /var/lib/secrets/restic-password)

        # 1. Récupérer les stats en JSON (snapshots raw)
        # On ne prend que le dernier snapshot pour éviter de parser tout l'historique (c'est lourd)
        LATEST_JSON=$(restic snapshots --json --latest 1)

        # Vérifier si on a réussi à parler à Restic
        if [ $? -ne 0 ]; then
          echo "restic_check_success 0" > $PROM_FILE
          exit 1
        fi

        # 2. Extraire le timestamp (CORRIGÉ : Suppression des nanosecondes)
        # La regex remplace ".123456Z" par "Z" pour que fromdate ne panique pas
        echo "$LATEST_JSON" | jq -r '.[0] | "restic_backup_timestamp " + (.time | sub("\\.[0-9]+Z$"; "Z") | fromdate | tostring)' > $PROM_FILE

        # 3. Récupérer la taille
        STATS_JSON=$(restic stats --mode raw-data --json)

        # Extraction de la taille totale (en octets)
        echo "$STATS_JSON" | jq -r '"restic_repo_size_bytes " + (.total_size | tostring)' >> $PROM_FILE

        # CORRECTION : On compte les snapshots au lieu des fichiers
        echo "$STATS_JSON" | jq -r '"restic_repo_snapshot_count " + (.snapshots_count | tostring)' >> $PROM_FILE

        # On peut aussi logger le taux de compression, c'est toujours satisfaisant pour l'ego
        echo "$STATS_JSON" | jq -r '"restic_compression_ratio " + (.compression_ratio | tostring)' >> $PROM_FILE

        echo "restic_check_success 1" >> $PROM_FILE

        echo "restic_check_success 1" >> $PROM_FILE
      '';
    };

    # 2. Le Timer (Lance le script 15min après le backup)
    systemd.timers.restic-stats = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "03:15"; # Un peu après le backup de 03:00
        Persistent = true;
      };
    };

  };
}
