{
  nodes = {

    vps1 = {
      publicIp = "";
      vpnIp = "10.100.0.1";
      ipv6 = "";
      ipv6_gateway = "";

      user = "root";
      sshKey = "~/.ssh/id_ed25519";
    };

    vps2 = {
      publicIp = "";
      vpnIp = "10.100.0.2";
      ipv6 = "";
      ipv6_gateway = "";

      user = "root";
      sshKey = "~/.ssh/id_ed25519";
    };

  };
}
