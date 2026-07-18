# -------------------------------------------------------------------------
# jellyfin.nix — Serveur multimédia Jellyfin
#
# Déploie Jellyfin sur le port 8096. La configuration (bibliothèques,
# utilisateurs, etc.) n'est pas gérée de manière déclarative — l'utilisateur
# copie son ancienne installation Jellyfin dans /var/lib/jellyfin.
#
# Le service écoute sur 0.0.0.0 par défaut (pas de --serviceaddress natif
# dans le module NixOS jellyfin). La sécurité est assurée par les ACLs qui
# restreignent l'accès au port 8096 aux IPs VPN du tag web-server.
#
# Tags requis : `applications/jellyfin`
# -------------------------------------------------------------------------
{
  config,
  services,
  lib,
  ...
}:

let
  cfg = config.infra.jellyfin;
  tag = "applications/jellyfin";
  enabled = services.hasTag tag;
  port = 8096;
  dataDir = "/var/lib/jellyfin";
in
{
  # Public API
  options.infra.jellyfin = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique de l'instance Jellyfin (ex: https://jellyfin.example.com).";
    };
  };

  config = lib.mkMerge [
    # Module contract
    { infra.registeredTags = [ tag ]; }

    # Local configuration
    (lib.mkIf enabled {
      services.jellyfin = {
        enable = true;
        openFirewall = false;
      };

      systemd.services.jellyfin-daily-restart = {
        description = "Restart Jellyfin to limit memory growth";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${config.systemd.package}/bin/systemctl restart jellyfin.service";
        };
      };

      systemd.timers.jellyfin-daily-restart = {
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "*-*-* 04:45:00";
      };

      infra.backup.paths = [ dataDir ];

      infra.security.acls = [
        {
          port = port;
          allowedTags = [ "web-server" ];
          description = "Jellyfin";
        }
      ];
    })
    # Fleet-wide contributions
    (lib.mkIf (services.getVpnIpsByTag tag != [ ] && cfg.url != null) {
      infra.ingress."jellyfin" = {
        url = cfg.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);
      };
    })
  ];
}
