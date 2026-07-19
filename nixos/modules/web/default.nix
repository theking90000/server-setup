# -------------------------------------------------------------------------
# web/default.nix — Modules web / reverse proxy
#
# Modules :
#   - ingress  : déclare l'option `infra.ingress` (endpoints et routes HTTPS)
#   - nginx    : compilateur ingress → virtualHosts Nginx + VTS, claims
#                ACME et certificats câblés via useACMEHost
# -------------------------------------------------------------------------
{
  imports = [
    ./ingress.nix
    ./nginx.nix
  ];
}
