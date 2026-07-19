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
  cfg = config.infra.filesave;
  tag = "applications/filesave-server";
  enabled = services.hasTag tag;
  port = 22551;
  dataDir = "/var/lib/filesave-server";
  package = pkgs.callPackage ../../pkgs/filesave/filesave-server.nix { };
in
{
  # Public API
  options.infra.filesave = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique du serveur FileSave (ex: https://filesave.example.com).";
    };
  };

  config = lib.mkMerge [
    # Module contract
    { infra.registeredTags = [ tag ]; }

    # Local configuration
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

          ExecStart = "${package}/bin/filesave-server";

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

    # Fleet-wide contributions
    (lib.mkIf (services.getVpnIpsByTag tag != [ ] && cfg.url != null) {
      infra.ingress."filesave-server" = {
        url = cfg.url;
        proxyTo = map (ip: "http://${ip}:${toString port}") (services.getVpnIpsByTag tag);
      };
    })
  ];
}
