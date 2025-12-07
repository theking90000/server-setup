{ ... }:
{
  # Proxy Grafana depuis vps1
  profile.grafana = {
    expose = true;
    exposeHost = "grafana.theking90000.be";
    exposeCert = "*.theking90000.be";

    grafanaHost = "vps1";
  };

  # Proxy Reposilite depuis vps1
  profile.reposilite = {
    expose = true;
    exposeHost = "repo.theking90000.be";
    exposeCert = "*.theking90000.be";
    reposiliteHost = "vps1";
  };
}
