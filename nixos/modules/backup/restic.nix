# -------------------------------------------------------------------------
# restic.nix — Sauvegardes automatiques via Restic
#
# Configure un backup Restic périodique (daily à 03:00) avec rétention
# (7 daily, 4 weekly, 6 monthly). Les credentials S3 et le mot de passe
# de chiffrement sont déployés via Colmena (hors /nix/store).
#
# Si le noeud a aussi `node-metrics`, génère des métriques Prometheus
# sur l'état du backup (timestamp, taille, snapshots).
#
# Tags requis : `backup`
# Secrets     : `infra.restic.{repository, password, env}` (Colmena)
# -------------------------------------------------------------------------
{
  config,
  lib,
  services,
  ops,
  pkgs,
  ...
}:

let
  enabled = services.hasTag "backup";
  p = config.infra.backup.paths;
in
{
  options.infra.restic = {
    repository = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL du repository Restic (ex: s3:https://s3.filebase.com/XXX).";
    };

    password = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Mot de passe de chiffrement du repository Restic (secret).";
    };

    env = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Variables d'environnement pour l'accès au repository (AWS keys, etc.) (secret).";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ "backup" ]; }
    (lib.mkIf enabled {
      deployment.keys = ops.mkSecretKeys "restic" config.infra.restic null;

      services.restic.backups."host-backup" = {
        initialize = true;

        repositoryFile = "/var/lib/secrets/restic/repository";
        passwordFile = "/var/lib/secrets/restic/password";
        environmentFile = "/var/lib/secrets/restic/env";

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
        ]
        ++ config.environment.systemPackages;

        script = ''
          # Fichier de sortie pour le collecteur textfile
          PROM_FILE="/var/lib/node_exporter/textfile_collector/restic.prom"

          # On récupère le dernier snapshot en JSON
          LATEST_JSON=$(restic-host-backup snapshots --json --latest 1)

          if [ $? -ne 0 ]; then
            echo "restic_check_success 0" > $PROM_FILE
            exit 1
          fi

          echo "$LATEST_JSON" | jq -r '.[0] | "restic_backup_timestamp " + (.time | sub("\\.[0-9]+Z$"; "Z") | fromdate | tostring)' > $PROM_FILE

          STATS_JSON=$(restic-host-backup stats --mode raw-data --json)

          echo "$STATS_JSON" | jq -r '"restic_repo_size_bytes " + (.total_size | tostring)' >> $PROM_FILE
          echo "$STATS_JSON" | jq -r '"restic_repo_snapshot_count " + (.snapshots_count | tostring)' >> $PROM_FILE
          echo "$STATS_JSON" | jq -r '"restic_compression_ratio " + (.compression_ratio | tostring)' >> $PROM_FILE

          echo "restic_check_success 1" >> $PROM_FILE
        '';
      };

      systemd.timers.restic-stats = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "03:15";
          Persistent = true;
        };
      };
    })
  ];
}
