# -------------------------------------------------------------------------
# monitoring/default.nix — Modules de monitoring
#
# Liste explicite des modules de monitoring et d'observabilité.
# Chaque module s'active via un tag correspondant dans `infra.nodes`.
#
# Modules :
#   - node-metrics : exporte les métriques système (tag: node-metrics)
#   - prometheus   : collecte et stocke les métriques (tag: prometheus)
#   - grafana      : dashboard de visualisation (tag: grafana)
# -------------------------------------------------------------------------
{
  imports = [
    ./node-metrics.nix
    ./prometheus.nix
    ./grafana.nix
  ];
}
