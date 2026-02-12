{
  lib,
  services,
  ops,
  config,
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
  ];
}
