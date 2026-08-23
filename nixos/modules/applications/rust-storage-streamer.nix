# -------------------------------------------------------------------------
# rust-storage-streamer.nix — Stockage Files et S3 adossé à Discord
#
# Réutilise le module NixOS autonome du projet. Files reste sur loopback ;
# S3 écoute sur WireGuard et est exposé par l'ingress HTTPS.
#
# Tag requis : `applications/rust-storage-streamer`
# Secret     : SOPS colocalisé dans secrets/rust-storage-streamer.json
# -------------------------------------------------------------------------
{
  config,
  lib,
  pkgs,
  services,
  ...
}:

let
  cfg = config.infra.rust-storage-streamer;
  tag = "applications/rust-storage-streamer";
  enabled = services.hasTag tag;
  hosts = services.getHostsByTag tag;
  vpnIps = services.getVpnIpsByTag tag;
  prometheusAvailable = services.getHostsByTag "prometheus" != [ ];
  metricsEnabled = enabled && prometheusAvailable;
  webhooksFile = "/run/secrets/rust-storage-streamer/webhooks";
  filesDataDir = "/var/lib/rust-storage-streamer-files";
  s3DataDir = "/var/lib/rust-storage-streamer-s3";
  filesDb = "${filesDataDir}/catalog.db";
  s3Db = "${s3DataDir}/s3-catalog.db";
  metricsDir = "/var/lib/node_exporter/textfile_collector";
  frameSize = 65536;
  s3Port = 8081;
in
{
  options.infra.rust-storage-streamer.s3Url = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "URL HTTPS publique du gateway S3.";
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }

    (lib.mkIf enabled {
      assertions = [
        {
          assertion = cfg.s3Url != null;
          message = "infra.rust-storage-streamer.s3Url is required on nodes tagged applications/rust-storage-streamer.";
        }
        {
          assertion = builtins.length hosts == 1;
          message = "Exactly one node may use applications/rust-storage-streamer because its SQLite catalogs are local.";
        }
        {
          assertion = services.getHostsByTag "web-server" != [ ];
          message = "A web-server node is required to expose the rust-storage-streamer S3 gateway.";
        }
        {
          assertion = cfg.s3Url == null || builtins.match "https://[^/]+/?" cfg.s3Url != null;
          message = "infra.rust-storage-streamer.s3Url must be an HTTPS origin without a path.";
        }
        {
          assertion = !prometheusAvailable || services.hasTag "node-metrics";
          message = "The rust-storage-streamer node requires the node-metrics tag when Prometheus is enabled.";
        }
      ];

      sops.secrets."rust-storage-streamer/webhooks" = {
        sopsFile = config.infra.sops.secretsDirectory + "/rust-storage-streamer.json";
        key = "webhooks";
        mode = "0400";
      };

      services.rust-storage-streamer = {
        # ponytail: keep the unauthenticated Files gateway on loopback until it gains auth.
        files = {
          enable = true;
          webhooksFile = webhooksFile;
          extraArgs = [
            "--frame-size"
            (toString frameSize)
          ];
        };
        s3 = {
          enable = true;
          listenAddress = services.getVpnIp;
          webhooksFile = webhooksFile;
          extraArgs = [
            "--frame-size"
            (toString frameSize)
          ];
        };
      };

      infra.security.acls = [
        {
          port = s3Port;
          allowedTags = [ "web-server" ];
          description = "Rust Storage Streamer S3";
        }
      ];

      infra.backup.paths = [
        filesDataDir
        s3DataDir
      ];
    })

    (lib.mkIf metricsEnabled {
      # node-metrics owns node_exporter, its ACL and the fleet-wide scrape job.
      # This unit only publishes application metrics into its textfile collector.
      systemd.services.rust-storage-streamer-catalog-metrics = {
        description = "Export rust-storage-streamer SQLite catalog metrics";
        after = [
          "rust-storage-streamer-files.service"
          "rust-storage-streamer-s3.service"
        ];

        path = [
          pkgs.coreutils
          pkgs.sqlite
        ];

        serviceConfig = {
          Type = "oneshot";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ metricsDir ];
        };

        script = ''
          set -euo pipefail

          output=${lib.escapeShellArg "${metricsDir}/s-streamer.prom"}
          temporary="$output.$$"
          trap 'rm -f "$temporary"' EXIT

          {
            cat <<'EOF'
          # HELP s_streamer_catalog_items Number of completed files or S3 objects.
          # TYPE s_streamer_catalog_items gauge
          # HELP s_streamer_catalog_logical_bytes Logical bytes visible to users.
          # TYPE s_streamer_catalog_logical_bytes gauge
          # HELP s_streamer_catalog_physical_bytes Encrypted attachment payload bytes represented by stored segments.
          # TYPE s_streamer_catalog_physical_bytes gauge
          # HELP s_streamer_catalog_incomplete_items Number of incomplete files.
          # TYPE s_streamer_catalog_incomplete_items gauge
          # HELP s_streamer_catalog_incomplete_expected_bytes Expected logical bytes for incomplete files.
          # TYPE s_streamer_catalog_incomplete_expected_bytes gauge
          # HELP s_streamer_catalog_buckets Number of S3 buckets.
          # TYPE s_streamer_catalog_buckets gauge
          # HELP s_streamer_catalog_multipart_uploads Number of active S3 multipart uploads.
          # TYPE s_streamer_catalog_multipart_uploads gauge
          # HELP s_streamer_catalog_orphaned_bytes Encrypted bytes held by orphaned S3 segments.
          # TYPE s_streamer_catalog_orphaned_bytes gauge
          # HELP s_streamer_catalog_last_success_unixtime Unix time of the last successful collection.
          # TYPE s_streamer_catalog_last_success_unixtime gauge
          EOF

            sqlite3 -readonly -batch -noheader -cmd ".timeout 5000" \
              ${lib.escapeShellArg filesDb} <<'SQL'
          SELECT 's_streamer_catalog_items{gateway="files"} ' ||
                 COUNT(*)
          FROM files
          WHERE completed_at IS NOT NULL;

          SELECT 's_streamer_catalog_logical_bytes{gateway="files"} ' ||
                 COALESCE(SUM(size), 0)
          FROM files
          WHERE completed_at IS NOT NULL;

          SELECT 's_streamer_catalog_physical_bytes{gateway="files"} ' ||
                 (COALESCE(SUM(frame_count), 0) * ${toString frameSize})
          FROM segments;

          SELECT 's_streamer_catalog_incomplete_items{gateway="files"} ' ||
                 COUNT(*)
          FROM files
          WHERE completed_at IS NULL;

          SELECT 's_streamer_catalog_incomplete_expected_bytes{gateway="files"} ' ||
                 COALESCE(SUM(expected_size), 0)
          FROM files
          WHERE completed_at IS NULL;
          SQL

            sqlite3 -readonly -batch -noheader -cmd ".timeout 5000" \
              ${lib.escapeShellArg s3Db} <<'SQL'
          SELECT 's_streamer_catalog_items{gateway="s3"} ' ||
                 COUNT(*)
          FROM objects;

          SELECT 's_streamer_catalog_logical_bytes{gateway="s3"} ' ||
                 COALESCE(SUM(size), 0)
          FROM objects;

          SELECT 's_streamer_catalog_physical_bytes{gateway="s3"} ' ||
                 (COALESCE(SUM(frame_count), 0) * ${toString frameSize})
          FROM segments;

          SELECT 's_streamer_catalog_buckets{gateway="s3"} ' ||
                 COUNT(*)
          FROM buckets;

          SELECT 's_streamer_catalog_multipart_uploads{gateway="s3"} ' ||
                 COUNT(*)
          FROM multipart_uploads;

          SELECT 's_streamer_catalog_orphaned_bytes{gateway="s3"} ' ||
                 (COALESCE(SUM(frame_count), 0) * ${toString frameSize})
          FROM segments
          WHERE orphaned_at IS NOT NULL;
          SQL

            echo "s_streamer_catalog_last_success_unixtime $(date +%s)"
          } > "$temporary"

          chmod 0644 "$temporary"
          mv "$temporary" "$output"
          trap - EXIT
        '';
      };

      systemd.timers.rust-storage-streamer-catalog-metrics = {
        description = "Refresh rust-storage-streamer catalog metrics";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1m";
          OnUnitActiveSec = "5m";
        };
      };
    })

    (lib.mkIf (vpnIps != [ ] && cfg.s3Url != null) {
      infra.ingress."rust-storage-streamer-s3" = {
        url = cfg.s3Url;
        proxyTo = map (ip: "http://${ip}:${toString s3Port}") vpnIps;
        routes.main.nginx.extraConfig = ''
          client_max_body_size 0;
          proxy_request_buffering off;
          proxy_buffering off;
          proxy_read_timeout 600s;
          proxy_send_timeout 600s;
        '';
      };
    })

    (lib.mkIf (hosts != [ ] && prometheusAvailable) {
      infra.grafana.dashboards = [ ./dashboards/s-streamer.json ];
    })
  ];
}
