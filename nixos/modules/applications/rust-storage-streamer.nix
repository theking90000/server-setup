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
  services,
  ...
}:

let
  cfg = config.infra.rust-storage-streamer;
  tag = "applications/rust-storage-streamer";
  enabled = services.hasTag tag;
  hosts = services.getHostsByTag tag;
  vpnIps = services.getVpnIpsByTag tag;
  webhooksFile = "/run/secrets/rust-storage-streamer/webhooks";
  filesDataDir = "/var/lib/rust-storage-streamer-files";
  s3DataDir = "/var/lib/rust-storage-streamer-s3";
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
        };
        s3 = {
          enable = true;
          listenAddress = services.getVpnIp;
          webhooksFile = webhooksFile;
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
  ];
}
