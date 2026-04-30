{
  nodes = {

    vps1 = {
      publicIp = "CHANGEME";
      vpnIp = "CHANGEME";
      ipv6 = "CHANGEME";
      ipv6_gateway = "CHANGEME";

      user = "root";
      sshKey = "CHANGEME";

      tags = [
        "web-server"
        "acme-issuer"
        "node-metrics"
        "backup"
      ];
    };

  };
}
