# -------------------------------------------------------------------------
# security/default.nix — Modules de sécurité
#
# Modules :
#   - acls         : pare-feu déclaratif par tag (nftables)
#   - acme         : certificats TLS Let's Encrypt + synchronisation (tag: acme-issuer)
#   - sso          : registre interne des clients et groupes applicatifs
#   - kanidm       : fournisseur d'identité SSO/OIDC/OAuth2/LDAPS (tag: kanidm)
#   - oauth2-proxy : SSO par proxy pour les apps sans OIDC natif (auto, sans tag)
# -------------------------------------------------------------------------
{
  imports = [
    ./acls.nix
    ./acme.nix
    ./sso.nix
    ./kanidm.nix
    ./oauth2-proxy.nix
  ];
}
