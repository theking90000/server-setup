{
  nodes = {

    vps1 = {
      publicIp = "CHANGEME";
      vpnIp = "CHANGEME";
      ipv6 = "CHANGEME";
      ipv6Gateway = "CHANGEME";

      publicInterface = "ens3"; # ← adapter au hardware (eth0, enp0s3, …)
      useDHCP = true; # ← false pour IP statique

      sshKey = "CHANGEME";
      sshPort = 22; # Port SSH final après infection

      tags = [
        "web-server"
        "acme-issuer"
        "node-metrics"
        "backup"
        # "kanidm"               # ← décommentez pour activer le provider SSO
      ];
    };

  };
}
