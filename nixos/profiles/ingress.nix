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

  # Proxy Gitea depuis vps1
  profile.gitea = {
    expose = true;
    exposeHost = "git.theking90000.be";
    exposeCert = "*.theking90000.be";
    giteaHost = "vps1";
  };
}
