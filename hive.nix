{ ... }:
{
  meta = {
    nixpkgs = <nixpkgs>;
  };
}
// (
  let
    topo = import ./inventory/topology.nix;

    generateNode = name: data: {

      deployment = {
        targetUser = data.user or "root";
        targetHost = data.publicIp;

        buildOnTarget = true;

        keys = {
          "wireguard.private" = {
            keyFile = ./. + "/.secrets/${name}/wireguard.private";
            destDir = "/var/lib/secrets";
            permissions = "0600";
          };
        };
      };

      imports = [
        (./nixos/hosts + "/${name}/profile.nix")

        (./.secrets + "/${name}/hardware.nix")

        ./.secrets/mesh.nix
      ];

      boot.tmp.cleanOnBoot = true;
      zramSwap.enable = true;
      services.openssh.enable = true;

      networking = {
        nftables.enable = true;

        interface.ens3 = {
          useDHCP = true;
          ipv6.addresses = [
            {
              address = data.ipv6;
              prefixLength = 128;
            }
          ];
        };

        defaultGateway6 = {
          address = data.ipv6_gateway;
          interface = "ens3";
        };
      };

    };
  in
  builtins.mapAttrs generateNode topo.nodes
)
