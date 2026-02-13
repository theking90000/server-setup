{
  vps1 = [
    "node-metrics"
    "prometheus"
    "backup"
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
  ];
}
