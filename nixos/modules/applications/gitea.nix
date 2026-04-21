{
  services,
  lib,
  ...
}:

let
  cfg = import ../../../config/gitea/gitea.nix;

  tag = "applications/gitea";
  port = 3003;

  enabled = services.hasTag tag;
in
{
  config = lib.mkMerge [
    (lib.mkIf enabled {
      # deployment.keys = ops.mkSecretKeys "gitea" cfg [ "accounts" ];

      services.gitea = {
        enable = true;
        stateDir = "/var/lib/gitea";

        settings = {
          server = {
            ROOT_URL = "${cfg.url}";
            HTTP_PORT = port;
            HTTP_ADDR = services.getVpnIp;
          };

          metrics = {
            ENABLED = true;
          };

          service = {
            DISABLE_REGISTRATION = !cfg.registrationEnabled;
          };
        };
      };

      infra.backup.paths = [ "/var/lib/gitea" ];

      # Ouverture du port pour Gitea
      infra.security.acls = [
        {
          port = port;
          allowedTags = [
            "web-server"
            "prometheus"
          ];
          description = "Gitea";
        }
      ];

    })
    {

      infra.telemetry."gitea" = map (host: {
        targets = [ "${host}:${toString port}" ];
        labels = {
          host = host;
        };
      }) (services.getHostsByTag tag);

    }

    (lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {

      infra.ingress."gitea" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] cfg.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);

        blockPaths = [ "/metrics" ];
      };

    })
  ];
}
