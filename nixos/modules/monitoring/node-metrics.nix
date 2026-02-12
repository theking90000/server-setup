{
  config,
  lib,
  services,
  ...
}:

let
  isEnabled = services.hasTag "node-metrics";
in
{
  config = lib.mkMerge [
    (lib.mkIf isEnabled {
      services.prometheus.exporters.node = {
        enable = true;
        port = 9100;

        openFirewall = false;
        listenAddress = services.getVpnIp;

        enabledCollectors = [
          "systemd"
          "processes"
          "textfile"
        ];
        extraFlags = [ "--collector.textfile.directory=/var/lib/node_exporter/textfile_collector" ];
      };

      infra.security.acls = [
        {
          port = 9100;
          allowedTags = [ "prometheus" ]; # <--- NixOS résoudra les IPs tout seul
          description = "Node Exporter Metrics";
        }
      ];
    })
    ({
      infra.telemetry."node-metrics" = builtins.map (host: {
        targets = [ "${host}:9100" ];
        labels = {
          host = host;
        };
      }) (services.getHostsByTag "node-metrics");
    })
  ];
}
