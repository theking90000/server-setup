{
  services,
  lib,
  pkgs,
  ...
}:

let
  mon-paquet = (pkgs.callPackage ../../pkgs/belgian-rail-data/belgian-rail-data.nix { });

  tag = "applications/belgian-rail-data";
  dataDir = "/var/lib/belgian-rail-data";

  port = 22551;

  enabled = services.hasTag tag;

  # cfg =
  #   if builtins.pathExists ../../../config/belgian-rail-data/belgian-rail-data.nix then
  #     import ../../../config/belgian-rail-data/belgian-rail-data.nix
  #   else
  #     { };
in
{
  config = lib.mkMerge [
    (lib.mkIf enabled {

      users.users.belgian-rail-data = {
        isSystemUser = true;
        group = "belgian-rail-data";

        home = dataDir;
        createHome = false;
      };

      users.groups.belgian-rail-data = { };

      # 2. Le Service Systemd
      systemd.services.belgian-rail-data = {
        description = "Belgian Rail Data Server";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        serviceConfig = {
          User = "belgian-rail-data";
          Group = "belgian-rail-data";

          StateDirectory = "belgian-rail-data";
          WorkingDirectory = dataDir;

          ExecStart = "${mon-paquet}/bin/belgian-rail-data --scheduler";

          Restart = "on-failure";
          RestartSec = "5s";

          ProtectSystem = "strict";
          ProtectHome = true;
          NoNewPrivileges = true;
        };
      };

    })

  ];
}
