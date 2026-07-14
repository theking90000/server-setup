{
  lib,
  services,
  ...
}:

let
  tag = "node-metrics";
  enabled = services.hasTag tag;
  port = 9100;
  textfileDir = "/var/lib/node_exporter/textfile_collector";
in
{
  config = lib.mkMerge [
    # Module contract
    { infra.registeredTags = [ tag ]; }

    # Local configuration
    (lib.mkIf enabled {
      services.prometheus.exporters.node = {
        enable = true;
        inherit port;

        openFirewall = false;
        listenAddress = services.getVpnIp;

        enabledCollectors = [
          "systemd"
          "processes"
          "textfile"
        ];
        extraFlags = [ "--collector.textfile.directory=${textfileDir}" ];
      };

      systemd.tmpfiles.rules = [
        "d ${textfileDir} 0755 nobody nogroup"
      ];

      infra.security.acls = [
        {
          inherit port;
          allowedTags = [ "prometheus" ];
          description = "Node Exporter Metrics";
        }
      ];
    })

    # Fleet-wide contributions
    {
      infra.telemetry."node-metrics" = map (host: {
        targets = [ "${host}:${toString port}" ];
        labels = { inherit host; };
      }) (services.getHostsByTag tag);
    }

    (lib.mkIf (services.getHostsByTag tag != [ ]) {
      infra.grafana.dashboards = [ ./dashboards/node-exporter.json ];
    })
  ];
}
