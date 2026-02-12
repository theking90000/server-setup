{
  lib,
  services,
  ops,
  config,
  pkgs,
  ...
}:
let
  enabled = services.hasTag "backup";
  cfg = (import ../../../config/restic/restic.nix);

  p = config.infra.backup.paths;
in
{
  config = lib.mkMerge [
    (lib.mkIf enabled {
      deployment.keys = ops.mkSecretKeys "restic" cfg null;

      services.restic.backups."host-backup" = {
        initialize = true;

        repositoryFile = "/var/lib/secrets/restic/repository";
        passwordFile = "/var/lib/secrets/restic/password";
        environmentFile = "/var/lib/secrets/restic/env";

        /*
          paths = [
            "/var/backup"
          ]
          ++ p;
        */
        paths = p;

        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];

        timerConfig = {
          OnCalendar = "03:00";
          Persistent = true;
        };
      };
    })
    (lib.mkIf (enabled && services.hasTag "node-metrics") {
      systemd.services.restic-stats = {
        description = "Générer les métriques Prometheus pour Restic";

        path = [
          pkgs.restic
          pkgs.jq
          pkgs.moreutils
          # pour avoir le wrapper restic-host-backup
        ]
        ++ config.environment.systemPackages; # moreutils pour 'sponge' ou juste redirection

        script = ''
          # Fichier de sortie
          PROM_FILE="/var/lib/node_exporter/textfile_collector/restic.prom"

          # 1. Récupérer les stats en JSON (snapshots raw)
          # On ne prend que le dernier snapshot pour éviter de parser tout l'historique (c'est lourd)
          LATEST_JSON=$(restic-host-backup snapshots --json --latest 1)

          # Vérifier si on a réussi à parler à Restic
          if [ $? -ne 0 ]; then
            echo "restic_check_success 0" > $PROM_FILE
            exit 1
          fi

          # 2. Extraire le timestamp (CORRIGÉ : Suppression des nanosecondes)
          # La regex remplace ".123456Z" par "Z" pour que fromdate ne panique pas
          echo "$LATEST_JSON" | jq -r '.[0] | "restic_backup_timestamp " + (.time | sub("\\.[0-9]+Z$"; "Z") | fromdate | tostring)' > $PROM_FILE

          # 3. Récupérer la taille
          STATS_JSON=$(restic-host-backup stats --mode raw-data --json)

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
    })
  ];
}
