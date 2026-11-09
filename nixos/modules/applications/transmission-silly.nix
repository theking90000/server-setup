{
  config,
  lib,
  pkgs,
  services,
  ...
}:
let
  cfg = config.infra.transmissionSilly;
  instance = "transmission-silly";
  tag = "applications/${instance}";
  enabled = services.hasTag tag;
  present = services.getHostsByTag tag != [ ];
  netns = config.infra.deluge.networkNamespace;
  mediaCfg = config.infra.servarrSilly.mediaGroup;
  dataDirectory = config.infra.deluge.dataDirectory;
  stateDir = "/var/lib/${instance}";
  port = 9091;
  settings = pkgs.writeText "${instance}-settings.json" (
    builtins.toJSON {
      rpc-enabled = true;
      rpc-bind-address = netns.namespaceAddress;
      rpc-port = port;
      rpc-authentication-required = true;
      rpc-username = "admin";
      rpc-whitelist-enabled = true;
      rpc-whitelist = "127.0.0.1,${netns.hostAddress},${netns.namespaceAddress}";
      rpc-host-whitelist-enabled = true;
      rpc-host-whitelist =
        if cfg.url == null then
          ""
        else
          lib.head (lib.splitString "/" (lib.removePrefix "https://" cfg.url));
      rpc-url = "/transmission/";
      port-forwarding-enabled = false;
      lpd-enabled = false;
      bind-address-ipv6 = "::1";
      umask = "007";
    }
  );
  prepare = pkgs.writeText "${instance}-prepare.py" ''
    import json, os
    from pathlib import Path

    path = Path("${stateDir}/settings.json")
    data = json.loads(path.read_text()) if path.exists() else {}
    data.setdefault("download-dir", "${dataDirectory}/transmission/downloads")
    data.setdefault("incomplete-dir", "${dataDirectory}/transmission/incomplete")
    data.setdefault("incomplete-dir-enabled", True)
    data.setdefault("peer-port", 51413)
    data.update(json.loads(Path("${settings}").read_text()))
    data["rpc-password"] = Path(os.environ["CREDENTIALS_DIRECTORY"], "rpc-password").read_text().strip()
    # Preserve user preferences and resume data, enforce authentication and
    # network restrictions, and never pass the password in process arguments.
    os.umask(0o077)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(data))
    temporary.chmod(0o600)
    temporary.replace(path)
  '';
in
{
  options.infra.transmissionSilly.url = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Public HTTPS URL of Transmission silly, using the Deluge HTTP Basic login and RPC password.";
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = services.hasTag "applications/deluge";
          message = "applications/transmission-silly requires applications/deluge on the same node for shared storage, credentials and VPN protection.";
        }
      ];
      sops.secrets."${instance}/rpc-password" = {
        sopsFile = config.infra.sops.secretsDirectory + "/deluge.json";
        key = "webui_password";
        restartUnits = [ "${instance}.service" ];
      };
      users.groups.${instance} = { };
      users.users.${instance} = {
        isSystemUser = true;
        group = instance;
        extraGroups = [ mediaCfg.name ];
        home = stateDir;
      };
      systemd.tmpfiles.rules = [
        "d ${dataDirectory}/transmission 2770 ${instance} ${mediaCfg.name} -"
        "d ${dataDirectory}/transmission/downloads 2770 ${instance} ${mediaCfg.name} -"
        "d ${dataDirectory}/transmission/incomplete 2770 ${instance} ${mediaCfg.name} -"
      ];
      systemd.services.${instance} = {
        description = "Independent Transmission instance in the Deluge provider VPN";
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
          CURL_CA_BUNDLE = config.security.pki.caBundle;
          TR_SAVE_VERSION_FORMAT = "4";
        };
        serviceConfig = {
          User = instance;
          Group = instance;
          SupplementaryGroups = [ mediaCfg.name ];
          StateDirectory = instance;
          StateDirectoryMode = "0700";
          WorkingDirectory = stateDir;
          LoadCredential = [ "rpc-password:/run/secrets/${instance}/rpc-password" ];
          ExecStartPre = "${pkgs.python3}/bin/python ${prepare}";
          ExecStart = "${pkgs.transmission_4}/bin/transmission-daemon -f -g ${stateDir}";
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
          TimeoutStopSec = 120;
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
          description = "Transmission silly WebUI and RPC relay";
        }
      ];
      infra.backup.paths = [ stateDir ];
    })
    (lib.mkIf (present && cfg.url != null) {
      infra.ingress.${instance} = {
        url = cfg.url;
        proxyTo = map (ip: "http://${ip}:${toString port}") (services.getVpnIpsByTag tag);
        routes.main.nginx.basicAuthFile = "/run/secrets/deluge/proxy-htpasswd";
      };
    })
  ];
}
