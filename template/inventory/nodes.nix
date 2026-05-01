{
  nodes = {

    vps1 = {
      publicIp = "CHANGEME";
      vpnIp = "CHANGEME";
      ipv6 = "CHANGEME";
      ipv6_gateway = "CHANGEME";

      publicInterface = "ens3";    # ← adapter au hardware (eth0, enp0s3, …)
      useDHCP = true;              # ← false pour IP statique

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
