# -------------------------------------------------------------------------
# web/default.nix — Modules web / reverse proxy
#
# Modules :
#   - ingress  : déclare l'option `infra.ingress` (routes HTTP)
#   - nginx    : reverse proxy Nginx + VTS, configure les virtualHosts
#                à partir de `infra.ingress` et des certificats ACME
# -------------------------------------------------------------------------
{
  imports = [
    ./ingress.nix
    ./nginx.nix
  ];
}
