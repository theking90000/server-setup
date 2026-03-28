{
  services,
  lib,
  pkgs,
  ...
}:

let
  mon-paquet = pkgs.callPackage ../../pkgs/filesave/filesave-server.nix { };

  tag = "applications/filesave-server";
  dataDir = "/var/lib/filesave-server";

  port = 22551;

  enabled = services.hasTag tag;

  cfg =
    if builtins.pathExists ../../../config/filesave/filesave.nix then
      import ../../../config/filesave/filesave.nix
    else
      { };
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

      infra.security.acls = [
        {
          port = port;
          allowedTags = [ "web-server" ];
          description = "Filesave Server";
        }
      ];

      infra.backup.paths = [ dataDir ];

    })

    (lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {

      infra.ingress."filesave-server" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] cfg.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);
      };

    })

  ];
}
