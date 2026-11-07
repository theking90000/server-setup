{
  config,
  lib,
  pkgs,
  services,
  ...
}:
let
  apps = {
    prowlarr = {
      option = "prowlarrSilly";
      displayName = "Prowlarr";
      port = 9697;
      directory = null;
    };
    sonarr = {
      option = "sonarrSilly";
      displayName = "Sonarr";
      port = 8990;
      directory = "series";
    };
    radarr = {
      option = "radarrSilly";
      displayName = "Radarr";
      port = 7879;
      directory = "movies";
    };
  };
  netns = config.infra.deluge.networkNamespace;
  dataDirectory = config.infra.deluge.dataDirectory;
  mkApp =
    name: app:
    let
      instance = "${name}-silly";
      cfg = config.infra.${app.option};
      tag = "applications/${instance}";
      enabled = services.hasTag tag;
      present = services.getHostsByTag tag != [ ];
      stateDir = "/var/lib/${instance}";
      prefix = lib.toUpper name;
      inherit (app) port;
    in
    lib.mkMerge [
      { infra.registeredTags = [ tag ]; }
      (lib.mkIf enabled {
        assertions = [
          {
            assertion = services.hasTag "applications/deluge";
            message = "applications/${instance} requires applications/deluge on the same node.";
          }
        ];
        sops.secrets."${instance}/api-key" = {
          sopsFile = config.infra.sops.secretsDirectory + "/${instance}.json";
          key = "api_key";
          restartUnits = [ "${instance}.service" ];
        };
        sops.templates."${instance}.env" = {
          content = ''
            ${prefix}__AUTH__APIKEY=${config.sops.placeholder."${instance}/api-key"}
          '';
          restartUnits = [ "${instance}.service" ];
        };
        systemd.tmpfiles.rules = lib.optionals (app.directory != null) [
          "d ${dataDirectory}/${app.directory} 2770 root deluge-media -"
        ];
        users.groups.${instance} = { };
        users.users.${instance} = {
          isSystemUser = true;
          group = "${instance}";
          home = stateDir;
        };
        systemd.services.${instance} = {
          description = "Independent ${app.displayName} instance in the Deluge provider VPN";
          wantedBy = [ "multi-user.target" ];
          requires = [ "deluge-vpn-guard.service" ];
          bindsTo = [ netns.unit ];
          after = [
            netns.unit
            "deluge-vpn-guard.service"
          ];
          partOf = [
            netns.unit
            "deluge-vpn-guard.service"
          ];
          environment = {
            "${prefix}__SERVER__BINDADDRESS" = netns.namespaceAddress;
            "${prefix}__SERVER__PORT" = toString port;
            "${prefix}__AUTH__METHOD" = if cfg.url != null then "External" else "Forms";
            "${prefix}__AUTH__REQUIRED" = "Enabled";
            "${prefix}__UPDATE__MECHANISM" = "External";
          };
          serviceConfig = {
            User = "${instance}";
            Group = "${instance}";
            SupplementaryGroups = lib.optional (app.directory != null) "deluge-media";
            StateDirectory = "${instance}";
            StateDirectoryMode = "0700";
            WorkingDirectory = stateDir;
            ExecStart = "${lib.getExe pkgs.${name}} -nobrowser -data=${stateDir}";
            EnvironmentFile = config.sops.templates."${instance}.env".path;
            NetworkNamespacePath = netns.path;
            BindReadOnlyPaths = [ "${netns.resolvConf}:/etc/resolv.conf" ];
            BindPaths = [ stateDir ] ++ lib.optional (app.directory != null) dataDirectory;
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
        systemd.sockets."${instance}-webui" = {
          wantedBy = [ "sockets.target" ];
          listenStreams = [ "${services.getVpnIp}:${toString port}" ];
          socketConfig.FreeBind = true;
        };
        systemd.services."${instance}-webui" = {
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
            description = "${app.displayName} VPN WebUI relay";
          }
        ];
        infra.backup = {
          paths = [ stateDir ];
          prepareCommands = [
            ''
              if [ -f ${stateDir}/${name}.db ]; then
                install -d -m0700 -o ${instance} -g ${instance} ${stateDir}/db-backup
                tmp=${stateDir}/db-backup/${name}.db.tmp
                rm -f "$tmp"
                ${pkgs.util-linux}/bin/runuser -u ${instance} -- \
                  ${lib.getExe pkgs.sqlite} ${stateDir}/${name}.db ".backup '$tmp'"
                mv "$tmp" ${stateDir}/db-backup/${name}.db
              fi
            ''
          ];
        };
      })
      (lib.mkIf (present && cfg.url != null) {
        infra.ingress.${instance} = {
          url = cfg.url;
          proxyTo = map (ip: "http://${ip}:${toString port}") (services.getVpnIpsByTag tag);
          routes.main.nginx.basicAuthFile = "/run/secrets/deluge/proxy-htpasswd";
        };
      })
    ];
in
{
  options.infra = lib.mapAttrs' (
    _: app:
    lib.nameValuePair app.option {
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Public HTTPS URL of the independent ${app.displayName} VPN instance, protected by the Deluge HTTP Basic login.";
      };
    }
  ) apps;
  config = lib.mkMerge (lib.mapAttrsToList mkApp apps);
}
