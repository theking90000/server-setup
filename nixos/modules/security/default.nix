# -------------------------------------------------------------------------
# security/default.nix — Modules de sécurité
#
# Modules :
#   - acls   : pare-feu déclaratif par tag (nftables)
#   - acme   : certificats TLS Let's Encrypt + synchronisation (tag: acme-issuer)
#   - kanidm : fournisseur d'identité SSO/OIDC/OAuth2/LDAPS (tag: kanidm)
# -------------------------------------------------------------------------
{
  imports = [
    ./acls.nix
    ./acme.nix
    ./kanidm.nix
  ];
}
