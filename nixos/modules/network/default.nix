# -------------------------------------------------------------------------
# network/default.nix — Modules réseau
#
# Modules :
#   - network    : configuration réseau de base (hostname, interfaces, sysctl)
#   - ssh        : serveur OpenSSH
#   - wireguard  : mesh VPN WireGuard entre tous les noeuds
# -------------------------------------------------------------------------
{
  imports = [
    ./network.nix
    ./ssh.nix
    ./wireguard.nix
  ];
}
