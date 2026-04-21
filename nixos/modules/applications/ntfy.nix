{
  services,
  lib,
  ...
}:

let
  cfg =
    if builtins.pathExists ../../../config/ntfy/ntfy.nix then
      import ../../../config/ntfy/ntfy.nix
    else
      { };

  tag = "applications/ntfy";
  port = 3004;

  dataDir = "/var/lib/ntfy-sh/user.db";

  enabled = services.hasTag tag;
in
{
  config = lib.mkMerge [
    (lib.mkIf (enabled && cfg != { }) {
      # deployment.keys = ops.mkSecretKeys "ntfy" cfg [ "accounts" ];

      services.ntfy-sh = {
        enable = true;
        # stateDir = dataDir;

        settings = {
          listen-http = "${services.getVpnIp}:${toString port}";
          base-url = cfg.url;

          behind-proxy = true;

          enable-metrics = true;

          upstream-base-url = cfg.upstream-base-url;
        };
      };

      infra.backup.paths = [ dataDir ];

      # Ouverture du port pour NTFY
      infra.security.acls = [
        {
          port = port;
          allowedTags = [
            "web-server"
            "prometheus"
          ];
          description = "NTFY";
        }
      ];

    })
    {

      infra.telemetry."ntfy" = map (host: {
        targets = [ "${host}:${toString port}" ];
        labels = {
          host = host;
        };
      }) (services.getHostsByTag tag);

    }

    (lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {

      infra.ingress."ntfy" = {
        domain = lib.replaceStrings [ "https://" ] [ "" ] cfg.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);

        blockPaths = [ "/metrics" ];
      };

    })
  ];
}
