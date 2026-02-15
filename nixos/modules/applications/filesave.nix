{
  services,
  lib,
  pkgs,
  ...
}:

let
  mon-paquet = pkgs.callPackage ../../pkgs/filesave/filesave-server.nix { };

  tag = "filesave-server";
  dataDir = "/var/lib/filesave-server";

  port = 22551;

  enabled = services.hasTag tag;
in
{
  config = lib.mkMerge [
    (lib.mkIf enabled {

      users.users.filesave = {
        isSystemUser = true;
        group = "filesave";

        home = dataDir;
        createHome = false;
      };

      users.groups.filesave = { };

      # 2. Le Service Systemd
      systemd.services.filesave-server = {
        description = "Filesave Server";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        environment = {
          BIND_ADDRESS = "${services.getVpnIp}:${toString port}";
        };

        serviceConfig = {
          User = "filesave";
          Group = "filesave";

          StateDirectory = "filesave-server";
          WorkingDirectory = dataDir;

          ExecStart = "${mon-paquet}/bin/filesave-server";

          Restart = "on-failure";
          RestartSec = "5s";

          ProtectSystem = "strict";
          ProtectHome = true;
          NoNewPrivileges = true;
        };
      };
    })

    {

    }

  ];
}
