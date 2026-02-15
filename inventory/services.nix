{
  vps1 = [
    "node-metrics"
    "backup"

    "web-server"
    "filesave-server"
  ];

  vps2 = [
    "node-metrics"
    "prometheus"
    "grafana"
    "acme-issuer"
    "web-server"
    "backup"

    "applications/docker-registry"
    "applications/reposilite"
    "applications/gitea"
  ];
}
