{
  services,
  lib,
  ops,
  ...
}:

let
  cfg = import ../../../config/docker-registry/docker-registry.nix;

  enabled = services.hasTag "applications/docker-registry";
in
{
  config = lib.mkMerge [
    (lib.mkIf enabled {
      deployment.keys = ops.mkSecretKeys "docker-registry" cfg [ "accounts" ];

      systemd.services.docker-registry.serviceConfig = {
        LoadCredential = [
          "admin_pwd:/var/lib/secrets/docker-registry/accounts"
        ];
      };

      services.dockerRegistry = {
        enable = true;
        port = 5000;
        listenAddress = services.getVpnIp;

        storagePath = "/var/lib/docker-registry";

        enableDelete = true;
        enableGarbageCollect = true;

        extraConfig = {
          auth = {
            htpasswd = {
              realm = "Registry";
              path = "/run/credentials/docker-registry.service/admin_pwd";
            };
          };

          http = {
            debug = {
              # On écoute sur le port 5001
              addr = "${services.getVpnIp}:5001";
              prometheus = {
                enabled = true;
                path = "/metrics";
              };
            };
          };
        };
      };

      infra.backup.paths = [ "/var/lib/docker-registry" ];

      infra.security.acls = [
        {
          port = 5991;
          allowedTags = [ "web-server" ];
          description = "Docker registry";
        }
        {
          port = 5001;
          allowedTags = [ "prometheus" ];
          description = "Docker registry metrics";
        }
      ];

    })
    (lib.mkIf (cfg.url != null) {

      infra.ingress."docker-registry" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] cfg.url;
        backend = map (ip: "${ip}:5000") (services.getVpnIpsByTag "applications/docker-registry");
      };

    })
    {

      infra.telemetry."docker-registry" = map (host: {
        targets = [ "${host}:5001" ];
        labels = {
          host = host;
        };
      }) (services.getHostsByTag "applications/docker-registry");

    }
  ];
}
