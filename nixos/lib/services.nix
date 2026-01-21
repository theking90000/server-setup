{
  lib,
  nodes,
  services,
  name,
}:

rec {
  # Syntactic Sugar : Vérifie si un noeud a un tag
  hasTag = tag: lib.elem tag (services."${name}" or [ ]);

  # Récupère la liste des hostnames qui possèdent un tag précis
  getHostsByTag = tag: lib.attrNames (lib.filterAttrs (name: tags: lib.elem tag tags) services);

  # La fonction "Killer Feature" :
  # Récupère directement les IPs VPN de tous les serveurs possédant un tag
  getVpnIpsByTag =
    tag:
    let
      hosts = getHostsByTag tag;
    in
    map (h: nodes."${h}".vpnIp) hosts;

  getVpnIp =
    let
      node = nodes."${name}";
    in
    node.vpnIp;

}
