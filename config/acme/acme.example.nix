{
  # Addresse Email utilisée sur letsencrypt pour l'obtention des certificats SSL)
  email = "";

  # Fournisseur DNS pour la validation des certificats SSL (ex: "ovh", "cloudflare", etc.)
  dnsProvider = "ovh";

  # Identifiants pour le fournisseur DNS
  # voir: https://go-acme.github.io/lego/dns/index.html
  dnsCredentials = ''
    OVH_ENDPOINT=ovh-eu
    OVH_APPLICATION_KEY=
    OVH_APPLICATION_SECRET=
    OVH_CONSUMER_KEY=
  '';
}
