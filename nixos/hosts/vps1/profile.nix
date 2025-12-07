{ ... }:
{
  # Make this an ingress node
  imports = [
    ./profiles/ingress.nix
  ];
  profile.nginx.enable = true;

  # Prometheus sur le VPS1
  profile.prometheus.enable = true;

  # Grafana sur le VPS1
  profile.grafana = {
    enable = true;
    rootUrl = "https://grafana.theking90000.be/";

    prometheusHost = "vps1";
  };

  # Docker-Registry sur le VPS1
  # Par défault: metrics sur prometheus
  profile.dockerRegistry.enable = true;

  # Reposilite
  profile.reposilite.enable = true;
  profile.reposilite.reposiliteHost = "vps1";

  profile.nginx.monitorHosts = [
    "vps1"
    "vps2"
  ];

  profile.certs = {
    email = "martin.cogh@gmail.com";
    issueDomains = [
      {
        domain = "*.theking90000.be";
        dnsProvider = "ovh";
        credentialsFile = "/var/lib/secrets/ovh-dns";
      }
    ];
  };
}
