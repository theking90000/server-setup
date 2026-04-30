# -------------------------------------------------------------------------
# security/default.nix — Modules de sécurité
#
# Modules :
#   - acls : pare-feu déclaratif par tag (nftables)
#   - acme : certificats TLS Let's Encrypt + synchronisation (tag: acme-issuer)
# -------------------------------------------------------------------------
{
  imports = [
    ./acls.nix
    ./acme.nix
  ];
}
