{
  # Politique d'émission ACME : chaque nœud émet localement les
  # certificats dont ses services ont besoin (challenge DNS-01).
  # Un suffixe couvre son apex et tous ses sous-domaines.
  # Les credentials DNS vont dans secrets/acme.json sous
  # issuers.primary.dnsCredentials (générés par init-project).
  infra.acme.issuers.primary = {
    match.suffixes = [ "CHANGEME" ]; # ex: "example.com"
    email = "CHANGEME";
    dnsProvider = "ovh";
  };
}
