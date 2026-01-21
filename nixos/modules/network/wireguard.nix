{
  name,
  ...
}:

let
  wg = import ../../../.secrets/mesh.nix;
in
{
  # Importer la clé
  deployment.keys."wg-key" = {
    keyFile = ../../../.secrets/${name}/wireguard.private;
    destDir = "/var/lib/secrets";
    user = "root";
    group = "root";
    permissions = "0400";
    name = "wg-key";
  };

  # Ouverture du port UDP pour Wireguard
  networking.firewall.allowedUDPPorts = [ 51820 ];

  # Configuration de l'interface Wireguard
  networking.wireguard.interfaces.wg0 = {
    ips = [ "${wg.mesh.${name}.vpnIp}/24" ];
    listenPort = 51820;

    privateKeyFile = "/var/lib/secrets/wg-key";

    peers = builtins.map (
      peerName:
      let
        peer = wg.mesh.${peerName};
      in
      {
        publicKey = peer.publicKey;
        allowedIPs = [ "${peer.vpnIp}/32" ];
        endpoint = "${peer.publicIp}:51820";
        persistentKeepalive = 25;
      }
    ) (builtins.attrNames (builtins.removeAttrs wg.mesh [ name ]));
  };

  # Configuration du DNS
  networking.hosts = builtins.listToAttrs (
    builtins.map (name: {
      name = wg.mesh.${name}.vpnIp;
      value = [ name ];
    }) (builtins.attrNames wg.mesh)
  );

}
