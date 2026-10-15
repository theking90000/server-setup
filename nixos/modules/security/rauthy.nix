# Rauthy is an independent identity application. Kanidm remains the provider
# used by infra.sso. This module runs one native Rauthy / Hiqlite instance.
{
  config,
  lib,
  pkgs,
  services,
  acme,
  ...
}:

let
  cfg = config.infra.rauthy;
  tag = "rauthy";
  enabled = services.hasTag tag;
  hosts = services.getHostsByTag tag;
  ips = services.getVpnIpsByTag tag;
  dataDir = "/var/lib/rauthy";
  backupDir = "${dataDir}/data/state_machine/backups";
  publicHost =
    if cfg.url == null then
      null
    else
      let match = builtins.match "https://([a-z0-9.-]+)/?" cfg.url;
      in if match == null then null else builtins.elemAt match 0;
  origin = if cfg.url == null then "" else lib.removeSuffix "/" cfg.url;
  configFile = (pkgs.formats.toml { }).generate "rauthy.toml" ({
    bootstrap.admin_email = if cfg.adminEmail == null then "" else cfg.adminEmail;
    cluster = {
      node_id = 1;
      nodes = [ "1 127.0.0.1:8100 127.0.0.1:8200" ];
      listen_addr_api = "127.0.0.1";
      listen_addr_raft = "127.0.0.1";
      data_dir = "${dataDir}/data";
      # Native exports reset Hiqlite's Raft metadata for restoration. Back up
      # these SQLite files rather than copying the live database and WAL.
      backup_cron = "0 30 * * * * *";
      backup_keep_days_local = 3;
    };
    database.hiqlite = true;
    email.rauthy_admin_email = if cfg.adminEmail == null then "" else cfg.adminEmail;
    hashing.max_hash_threads = cfg.maxHashThreads;
    server = {
      listen_address = services.getVpnIp;
      scheme = "http";
      port_http = cfg.port;
      pub_url = if publicHost == null then "" else publicHost;
      proxy_mode = true;
      trusted_proxies = map (ip: "${ip}/32") (services.getVpnIpsByTag "web-server");
      http_workers = cfg.httpWorkers;
      metrics_enable = true;
      metrics_addr = services.getVpnIp;
      metrics_port = cfg.metricsPort;
    };
    user_registration.enable = cfg.registrationEnabled;
    webauthn = {
      rp_id = if publicHost == null then "" else publicHost;
      rp_origin = origin;
      rp_name = "Rauthy";
    };
  } // lib.optionalAttrs (cfg.smtp != null) {
    email = {
      rauthy_admin_email = if cfg.adminEmail == null then "" else cfg.adminEmail;
      smtp_url = cfg.smtp.host;
      smtp_port = cfg.smtp.port;
      smtp_from = cfg.smtp.from;
      starttls_only = cfg.smtp.startTlsOnly;
    };
  });
in
{
  options.infra.rauthy = {
    package = lib.mkPackageOption pkgs "rauthy" { };
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public HTTPS origin of Rauthy, without a path or explicit port.";
    };
    adminEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Initial administrator email and administrative contact.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "HTTP port on the WireGuard address.";
    };
    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 9091;
      description = "Prometheus port on the WireGuard address.";
    };
    registrationEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow users to register their own accounts.";
    };
    httpWorkers = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Number of Rauthy HTTP workers.";
    };
    maxHashThreads = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Maximum concurrent password hashing operations.";
    };
    smtp = lib.mkOption {
      default = null;
      description = "SMTP delivery settings. Credentials belong in the Rauthy SOPS environment.";
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          host = lib.mkOption { type = lib.types.str; };
          port = lib.mkOption {
            type = lib.types.port;
            default = 465;
          };
          from = lib.mkOption { type = lib.types.str; };
          startTlsOnly = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
        };
      });
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }

    (lib.mkIf enabled {
      assertions = [
        {
          assertion = publicHost != null && acme.validDnsName publicHost;
          message = "infra.rauthy.url must be an HTTPS DNS origin without a path or explicit port.";
        }
        {
          assertion = cfg.adminEmail != null && cfg.adminEmail != "";
          message = "infra.rauthy.adminEmail is required on nodes tagged rauthy.";
        }
        {
          assertion = builtins.length hosts == 1;
          message = "The Rauthy module supports exactly one node; Hiqlite clustering is not configured.";
        }
        {
          assertion = services.getHostsByTag "web-server" != [ ];
          message = "Rauthy requires a web-server node for its public HTTPS origin.";
        }
        {
          assertion = cfg.port != cfg.metricsPort;
          message = "Rauthy HTTP and metrics ports must be different.";
        }
      ];

      sops.secrets."rauthy/environment" = {
        sopsFile = config.infra.sops.secretsDirectory + "/rauthy.json";
        key = "environment";
        mode = "0400";
        restartUnits = [ "rauthy.service" ];
      };

      users.groups.rauthy = { };
      users.users.rauthy = {
        isSystemUser = true;
        group = "rauthy";
        home = dataDir;
      };

      systemd.services.rauthy = {
        description = "Rauthy identity application";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          User = "rauthy";
          Group = "rauthy";
          StateDirectory = "rauthy";
          StateDirectoryMode = "0700";
          WorkingDirectory = dataDir;
          # Rauthy accepts its secrets through these native environment
          # variables. systemd reads the root-only SOPS file at each start.
          EnvironmentFile = config.sops.secrets."rauthy/environment".path;
          ExecStart = "${lib.getExe cfg.package} serve --config-file ${configFile} --secrets-file /dev/null";
          Restart = "on-failure";
          RestartSec = 5;
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          RestrictSUIDSGID = true;
        };
      };

      infra.security.acls = [
        {
          port = cfg.port;
          allowedTags = [ "web-server" ];
          description = "Rauthy HTTP";
        }
        {
          port = cfg.metricsPort;
          allowedTags = [ "prometheus" ];
          description = "Rauthy metrics";
        }
      ];
      infra.backup.paths = [ backupDir ];
      infra.backup.prepareCommands = [ ''
        if [ -z "$(${pkgs.findutils}/bin/find ${backupDir} -name 'backup_node_1_*.sqlite' -mmin +1 -mmin -120 -print -quit)" ]; then
          echo 'Rauthy has no recent Hiqlite backup; refusing a stale Restic backup.' >&2
          exit 1
        fi
      '' ];
    })

    {
      infra.telemetry.rauthy = map (host: {
        targets = [ "${host}:${toString cfg.metricsPort}" ];
        labels = { inherit host; };
      }) hosts;
    }

    (lib.mkIf (ips != [ ] && cfg.url != null) {
      infra.ingress.rauthy = {
        url = cfg.url;
        proxyTo = map (ip: "http://${ip}:${toString cfg.port}") ips;
        routes.metrics = {
          path = "/metrics";
          nginx.return = "403";
        };
      };
    })
  ];
}
