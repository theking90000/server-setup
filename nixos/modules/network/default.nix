# -------------------------------------------------------------------------
# network/default.nix — Modules réseau
#
# Modules :
#   - network    : configuration réseau de base (hostname, interfaces, sysctl)
#   - ssh        : serveur OpenSSH
#   - wireguard  : mesh VPN WireGuard entre tous les noeuds
#   - rclone-sync : montages distants via Rclone (S3, SFTP, WebDAV, …)
# -------------------------------------------------------------------------
{
  imports = [
    ./network.nix
    ./rclone-sync.nix
    ./ssh.nix
    ./wireguard.nix
  ];
}
