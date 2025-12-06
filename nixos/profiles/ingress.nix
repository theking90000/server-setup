{ ... }:
{
  # Proxy Grafana depuis vps1
  profile.grafana = {
    expose = true;
    exposeHost = "grafana.theking90000.be";
    exposeCert = "*.theking90000.be";

    grafanaHost = "vps1";
  };
}
