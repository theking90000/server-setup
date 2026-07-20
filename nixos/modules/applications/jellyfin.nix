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
  pkgs,
  ...
}:

let
  cfg = config.infra.jellyfin;
  tag = "applications/jellyfin";
  enabled = services.hasTag tag;
  port = 8096;
  dataDir = "/var/lib/jellyfin";
  localUrl = "http://127.0.0.1:${toString port}";
  jellarrWaitReady = pkgs.writeShellScript "jellarr-wait-ready" ''
    for _ in $(${pkgs.coreutils}/bin/seq 1 120); do
      if ${pkgs.curl}/bin/curl --fail --silent --output /dev/null \
        --header "X-Emby-Token: $JELLARR_API_KEY" \
        ${localUrl}/System/Configuration; then
        exit 0
      fi

      ${pkgs.coreutils}/bin/sleep 1
    done

    echo "Jellyfin configuration API did not become ready at ${localUrl}" >&2
    exit 1
  '';
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

      sops.secrets."jellyfin/jellarr-api-key" = {
        sopsFile = config.infra.sops.secretsDirectory + "/jellyfin.json";
        key = "jellarr_api_key";
        mode = "0400";
      };

      sops.templates."jellarr.env" = {
        content = ''
          JELLARR_API_KEY=${config.sops.placeholder."jellyfin/jellarr-api-key"}
        '';
        owner = config.services.jellarr.user;
        group = config.services.jellarr.group;
        mode = "0400";
      };

      services.jellarr = {
        enable = true;
        environmentFile = config.sops.templates."jellarr.env".path;
        bootstrap = {
          enable = true;
          apiKeyFile = config.sops.secrets."jellyfin/jellarr-api-key".path;
        };
        config = {
          version = 1;
          base_url = localUrl;
          system.enableMetrics = true;
        };
      };

      systemd.services.jellarr = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStartPre = lib.mkAfter [ jellarrWaitReady ];
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
          allowedTags = [
            "web-server"
            "prometheus"
          ];
          description = "Jellyfin";
        }
      ];
    })
    # Fleet-wide contributions
    {
      infra.telemetry."jellyfin" = map (host: {
        targets = [ "${host}:${toString port}" ];
        labels = { inherit host; };
      }) (services.getHostsByTag tag);
    }
    (lib.mkIf (services.getVpnIpsByTag tag != [ ] && cfg.url != null) {
      infra.ingress."jellyfin" = {
        url = cfg.url;
        proxyTo = map (ip: "http://${ip}:${toString port}") (services.getVpnIpsByTag tag);
        routes.metrics = {
          path = "/metrics";
          nginx.return = "403";
        };
      };
    })
  ];
}
