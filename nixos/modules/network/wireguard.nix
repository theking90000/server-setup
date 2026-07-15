# -------------------------------------------------------------------------
# wireguard.nix — Mesh VPN WireGuard entre tous les noeuds
#
# Configure l'interface wg0 avec un maillage complet (full mesh) :
# chaque noeud est peer de tous les autres. La topologie est lue
# depuis `config.infra.nodes` fourni par le repo privé.
#
# La clé privée WireGuard est déclarée ici via SOPS. L'option
# `infra.wireguard.privateKeyFile` reste disponible pour injecter un autre
# chemin runtime, notamment dans les tests.
#
# Nécessite que chaque noeud de `infra.nodes` ait :
#   - vpnIp               : IP virtuelle dans le mesh
#   - publicIp            : endpoint public
#   - wireguardPublicKey  : clé publique WireGuard
#
# Ouvre le port UDP 51820 et peuple /etc/hosts avec les IPs VPN.
# -------------------------------------------------------------------------
{ config, lib, ... }:

let
  nodeName = config.infra.nodeName;
  nodes = config.infra.nodes;

  me = nodes.${nodeName};

  useSops = config.infra.wireguard.privateKeyFile == null;
  privateKeyPath =
    if useSops then "/run/secrets/wireguard/private-key" else config.infra.wireguard.privateKeyFile;

  peerNames = builtins.attrNames (builtins.removeAttrs nodes [ nodeName ]);
in
{
  options.infra.wireguard.privateKeyFile = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Chemin runtime alternatif de la clé privée WireGuard.";
  };

  config = {
    sops.secrets."wireguard/private-key" = lib.mkIf useSops {
      sopsFile = config.infra.sops.secretsDirectory + "/wireguard/${nodeName}.json";
      key = "privateKey";
      mode = "0400";
    };

    networking.firewall.allowedUDPPorts = [ 51820 ];

    networking.wireguard.interfaces.wg0 = lib.mkIf (me.vpnIp != null) {
      ips = [ "${me.vpnIp}/24" ];
      listenPort = 51820;

      privateKeyFile = privateKeyPath;

      peers = map (
        peerName:
        let
          peer = nodes.${peerName};
        in
        {
          publicKey = peer.wireguardPublicKey;
          allowedIPs = [ "${peer.vpnIp}/32" ];
          endpoint = "${peer.publicIp}:51820";
          persistentKeepalive = 25;
        }
      ) peerNames;
    };

    networking.hosts = builtins.listToAttrs (
      map (n: {
        name = nodes.${n}.vpnIp;
        value = [ n ];
      }) (builtins.attrNames nodes)
    );
  };
}
