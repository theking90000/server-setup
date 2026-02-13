{
  services,
  lib,
  pkgs,
  ...
}:

let
  cfg = import ../../../config/reposilite/reposilite.nix;

  tag = "applications/reposilite";
  port = 5002;

  enabled = services.hasTag tag;
in
{
  config = lib.mkMerge [
    (lib.mkIf enabled {
      # deployment.keys = ops.mkSecretKeys "reposilite" cfg [ "accounts" ];

      services.reposilite = {
        enable = true;
        workingDirectory = "/var/lib/reposilite";

        openFirewall = false;

        settings = {
          port = port;
          hostname = services.getVpnIp;
        };

        plugins = with pkgs.reposilitePlugins; [
          checksum
          prometheus
        ];
      };

      systemd.services.reposilite.environment = {
        REPOSILITE_PROMETHEUS_USER = "user";
        REPOSILITE_PROMETHEUS_PASSWORD = "password";
      };

      infra.backup.paths = [ "/var/lib/reposilite" ];

      # Ouverture du port pour Reposilite
      infra.security.acls = [
        {
          port = port;
          allowedTags = [
            "web-server"
            "prometheus"
          ];
          description = "Reposilite";
        }
      ];

    })
    {

      infra.telemetry."reposilite" = map (host: {
        targets = [ "${host}:${toString port}" ];
        labels = {
          host = host;
        };
      }) (services.getHostsByTag tag);

    }

    (lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {

      infra.ingress."reposilite" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] cfg.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);

        blockPaths = [ "/metrics" ];
      };

    })
  ];
}
