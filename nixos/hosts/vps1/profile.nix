{ ... }:
{
    # Prometheus sur le VPS1
    profile.prometheus = {
        enable = true;
    };

    # Grafana sur le VPS1
    profile.grafana = {
        enable = true;
        prometheusHost = "vps1"; # <--- C'est ici que la magie opère
        adminPasswordFile = "/var/lib/secrets/grafana-admin";
    };
}