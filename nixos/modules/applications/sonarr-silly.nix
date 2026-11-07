{
  config,
  lib,
  pkgs,
  services,
  ...
}:
let
  cfg = config.infra.sonarrSilly;
  tag = "applications/sonarr-silly";
  enabled = services.hasTag tag;
  present = services.getHostsByTag tag != [ ];
  netns = config.infra.deluge.networkNamespace;
  dataDirectory = config.infra.deluge.dataDirectory;
  stateDir = "/var/lib/sonarr-silly";
  port = 8990;
in
{
  options.infra.sonarrSilly.url = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Public HTTPS URL of the independent Sonarr VPN instance, protected by the Deluge HTTP Basic login.";
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = services.hasTag "applications/deluge";
          message = "applications/sonarr-silly requires applications/deluge on the same node.";
        }
      ];
      sops.secrets."sonarr-silly/api-key" = {
        sopsFile = config.infra.sops.secretsDirectory + "/sonarr-silly.json";
        key = "api_key";
        restartUnits = [ "sonarr-silly.service" ];
      };
      sops.templates."sonarr-silly.env" = {
        content = ''
          SONARR__AUTH__APIKEY=${config.sops.placeholder."sonarr-silly/api-key"}
        '';
        restartUnits = [ "sonarr-silly.service" ];
      };
      users.groups.sonarr-silly = { };
      users.users.sonarr-silly = {
        isSystemUser = true;
        group = "sonarr-silly";
        home = stateDir;
      };
      systemd.services.sonarr-silly = {
        description = "Independent Sonarr instance in the Deluge provider VPN";
        wantedBy = [ "multi-user.target" ];
        requires = [ "deluge-vpn-guard.service" ];
        bindsTo = [ netns.unit ];
        after = [
          netns.unit
          "deluge-vpn-guard.service"
        ];
        partOf = [ netns.unit ];
        environment = {
          SONARR__SERVER__BINDADDRESS = netns.namespaceAddress;
          SONARR__SERVER__PORT = toString port;
          SONARR__AUTH__METHOD = if cfg.url != null then "External" else "Forms";
          SONARR__AUTH__REQUIRED = "Enabled";
          SONARR__UPDATE__MECHANISM = "External";
        };
        serviceConfig = {
          User = "sonarr-silly";
          Group = "sonarr-silly";
          SupplementaryGroups = [ "deluge-media" ];
          StateDirectory = "sonarr-silly";
          StateDirectoryMode = "0700";
          WorkingDirectory = stateDir;
          ExecStart = "${lib.getExe pkgs.sonarr} -nobrowser -data=${stateDir}";
          EnvironmentFile = config.sops.templates."sonarr-silly.env".path;
          NetworkNamespacePath = netns.path;
          BindReadOnlyPaths = [ "${netns.resolvConf}:/etc/resolv.conf" ];
          BindPaths = [
            stateDir
            dataDirectory
          ];
          TemporaryFileSystem = [
            "/var/lib:ro"
            "/mnt:ro"
            "/srv:ro"
          ];
          InaccessiblePaths = [
            "-/run/secrets"
            "-/var/backups"
            "-/var/log"
          ];
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          PrivateUsers = false;
          NoNewPrivileges = true;
          RestrictSUIDSGID = true;
          RestrictNamespaces = true;
          LockPersonality = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          ProtectProc = "invisible";
          CapabilityBoundingSet = "";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
            "AF_NETLINK"
          ];
          UMask = "0007";
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
      systemd.sockets.sonarr-silly-webui = {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "${services.getVpnIp}:${toString port}" ];
        socketConfig.FreeBind = true;
      };
      systemd.services.sonarr-silly-webui = {
        requires = [ netns.unit ];
        after = [
          netns.unit
          "deluge-vpn-guard.service"
        ];
        serviceConfig.ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${netns.namespaceAddress}:${toString port}";
      };
      infra.security.acls = [
        {
          inherit port;
          allowedTags = [ "web-server" ];
          description = "Sonarr VPN WebUI relay";
        }
      ];
      infra.backup = {
        paths = [ stateDir ];
        prepareCommands = [
          ''
            if [ -f ${stateDir}/sonarr.db ]; then
              install -d -m0700 -o sonarr-silly -g sonarr-silly ${stateDir}/db-backup
              tmp=${stateDir}/db-backup/sonarr.db.tmp
              rm -f "$tmp"
              ${pkgs.util-linux}/bin/runuser -u sonarr-silly -- \
                ${lib.getExe pkgs.sqlite} ${stateDir}/sonarr.db ".backup '$tmp'"
              mv "$tmp" ${stateDir}/db-backup/sonarr.db
            fi
          ''
        ];
      };
    })
    (lib.mkIf (present && cfg.url != null) {
      infra.ingress.sonarr-silly = {
        url = cfg.url;
        proxyTo = map (ip: "http://${ip}:${toString port}") (services.getVpnIpsByTag tag);
        routes.main.nginx.basicAuthFile = "/run/secrets/deluge/proxy-htpasswd";
      };
    })
  ];
}
