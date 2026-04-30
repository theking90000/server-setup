# -------------------------------------------------------------------------
# filesave.nix — Serveur de partage de fichiers
#
# Déploie le serveur filesave-server (package custom) écoutant sur
# l'IP VPN (port 22551). Si une URL publique est configurée, déclare
# automatiquement les ACLs et l'ingress Nginx.
#
# La configuration est optionnelle (le module fonctionne sans si le
# fichier de config n'existe pas dans le repo privé).
#
# Tags requis : `applications/filesave-server`
# -------------------------------------------------------------------------
{
  config,
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
in
{
  options.infra.filesave = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique du serveur FileSave (ex: https://filesave.example.com).";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }
    (lib.mkIf enabled {
      users.users.filesave = {
        isSystemUser = true;
        group = "filesave";

        home = dataDir;
        createHome = false;
      };

      users.groups.filesave = { };

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
    (lib.mkIf (config.infra.filesave.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."filesave-server" = {
        url = config.infra.filesave.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);
      };
    })
  ];
}
