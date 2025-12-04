{ ... }:
{
  # Prometheus sur le VPS1
  profile.prometheus.enable = true;

  # Grafana sur le VPS1
  profile.grafana = {
    enable = true;
    prometheusHost = "vps1"; # <--- C'est ici que la magie opère
  };

  # Docker-Registry sur le VPS1
  profile.dockerRegistry.enable = true;

  profile.certs = {
    email = "martin.cogh@gmail.com";
    issueDomains = [
      {
        domain = "vps1.theking90000.be";
        dnsProvider = "ovh";
        credentialsFile = "/var/lib/secrets/ovh-dns";
      }
    ];
  };
}
