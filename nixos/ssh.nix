{ name, ... }:
{
  services.openssh = {
    enable = true;

    openFirewall = true;

    settings = {
      PermitRootLogin = "prohibit-password";

      PasswordAuthentication = false;
    };
  };

  networking.firewall.allowedTCPPorts = [ 22 ];

  users.users.root.openssh.authorizedKeys.keys = [
    (builtins.readFile (../.secrets + "/${name}/key.pub"))
  ];
}
