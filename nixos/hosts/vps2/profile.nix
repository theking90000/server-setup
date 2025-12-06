{ ... }:
{
  imports = [
    ./profiles/ingress.nix
  ];

  profile.certs = {
    syncDomains = [ "*.theking90000.be" ];
    masterIp = "vps1";
  };

  profile.nginx.enable = true;
}
