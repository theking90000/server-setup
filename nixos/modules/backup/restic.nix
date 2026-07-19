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
# Secrets     : SOPS colocalisé, avec options texte/*File pour compatibilité
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
  cfg = config.infra.restic;
  tag = "backup";
  enabled = services.hasTag tag;
  backupPaths = config.infra.backup.paths;
  backupPrepareCommands = config.infra.backup.prepareCommands;

  repositoryPath =
    if cfg.repositoryFile != null then
      cfg.repositoryFile
    else if cfg.repository != null then
      "/var/lib/secrets/restic/repository"
    else
      "/run/secrets/restic/repository";
  passwordPath =
    if cfg.passwordFile != null then
      cfg.passwordFile
    else if cfg.password != null then
      "/var/lib/secrets/restic/password"
    else
      "/run/secrets/restic/password";
  envPath =
    if cfg.envFile != null then
      cfg.envFile
    else if cfg.env != null then
      "/var/lib/secrets/restic/env"
    else
      "/run/secrets/restic/env";
  useSopsRepository = enabled && cfg.repository == null && cfg.repositoryFile == null;
  useSopsPassword = enabled && cfg.password == null && cfg.passwordFile == null;
  useSopsEnv = enabled && cfg.env == null && cfg.envFile == null;
  sopsSecret = key: {
    sopsFile = config.infra.sops.secretsDirectory + "/restic.json";
    inherit key;
  };
in
{
  # Public API
  options.infra.restic = {
    repository = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL du repository Restic (ex: s3:https://s3.filebase.com/XXX).";
    };

    repositoryFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Chemin runtime contenant l'URL du repository Restic.";
    };

    password = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Mot de passe de chiffrement du repository Restic (secret).";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Chemin runtime contenant le mot de passe Restic.";
    };

    env = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Variables d'environnement pour l'accès au repository (AWS keys, etc.) (secret).";
    };

    envFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Chemin runtime facultatif des variables d'environnement Restic.";
    };
  };

  config = lib.mkMerge [
    # Module contract
    { infra.registeredTags = [ tag ]; }

    {
      sops.secrets = {
        "restic/repository" = lib.mkIf useSopsRepository (sopsSecret "repository");
        "restic/password" = lib.mkIf useSopsPassword (sopsSecret "password");
        "restic/env" = lib.mkIf useSopsEnv (sopsSecret "env");
      };
    }

    # Local configuration
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = cfg.repository == null || cfg.repositoryFile == null;
          message = "Set at most one of infra.restic.repository or infra.restic.repositoryFile on backup nodes.";
        }
        {
          assertion = cfg.password == null || cfg.passwordFile == null;
          message = "Set at most one of infra.restic.password or infra.restic.passwordFile on backup nodes.";
        }
        {
          assertion = cfg.env == null || cfg.envFile == null;
          message = "Set at most one of infra.restic.env or infra.restic.envFile.";
        }
      ];

      deployment.keys = ops.mkSecretKeys "restic" {
        repository = if cfg.repositoryFile == null then cfg.repository else null;
        password = if cfg.passwordFile == null then cfg.password else null;
        env = if cfg.envFile == null then cfg.env else null;
      } null;

      services.restic.backups."host-backup" = {
        initialize = true;

        repositoryFile = repositoryPath;
        passwordFile = passwordPath;
        paths = backupPaths;

        # ponytail: dépôt partagé entre nœuds, tous à 03:00 -> attendre le
        # verrou plutôt qu'échouer. Décaler les timers si les backups traînent.
        extraBackupArgs = [ "--retry-lock 2h" ];

        backupPrepareCommand = lib.mkIf (backupPrepareCommands != [ ]) (
          lib.concatStringsSep "\n" backupPrepareCommands
        );

        pruneOpts = [
          "--retry-lock 6h"
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];

        timerConfig = {
          OnCalendar = "03:00";
          # ponytail: étale les démarrages sur les nœuds partageant le dépôt
          # pour réduire la collision de verrou en amont du --retry-lock.
          RandomizedDelaySec = "30min";
          Persistent = true;
        };
      }
      // lib.optionalAttrs (cfg.env != null || cfg.envFile != null || useSopsEnv) {
        environmentFile = envPath;
      };
    })

    # Optional local metrics
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
