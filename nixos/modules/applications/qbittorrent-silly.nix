{
  config,
  lib,
  pkgs,
  services,
  ...
}:
let
  cfg = config.infra.qbittorrentSilly;
  instance = "qbittorrent-silly";
  tag = "applications/${instance}";
  enabled = services.hasTag tag;
  present = services.getHostsByTag tag != [ ];
  netns = config.infra.deluge.networkNamespace;
  mediaCfg = config.infra.servarrSilly.mediaGroup;
  dataDirectory = config.infra.deluge.dataDirectory;
  stateDir = "/var/lib/${instance}";
  port = 8081;
  settings = pkgs.writeText "${instance}-settings.json" (
    builtins.toJSON {
      Preferences = {
        "WebUI\\Address" = netns.namespaceAddress;
        "WebUI\\Port" = toString port;
        "WebUI\\Username" = "admin";
        "WebUI\\LocalHostAuth" = "true";
        "WebUI\\AuthSubnetWhitelistEnabled" = "false";
        "WebUI\\HostHeaderValidation" = "true";
        "WebUI\\ServerDomains" =
          if cfg.url == null then
            "localhost"
          else
            lib.head (lib.splitString "/" (lib.removePrefix "https://" cfg.url));
        "WebUI\\CSRFProtection" = "true";
        "WebUI\\ClickjackingProtection" = "true";
        "WebUI\\HTTPS\\Enabled" = "false";
      };
      BitTorrent = {
        "Session\\Interface" = "wg-qbt";
        "Session\\InterfaceName" = "wg-qbt";
        "Session\\Port" = "51414";
        "Session\\LSDEnabled" = "false";
      };
      Network.PortForwardingEnabled = "false";
    }
  );
  prepare = pkgs.writeText "${instance}-prepare.py" ''
    import base64, configparser, hashlib, json, os, secrets
    from pathlib import Path

    path = Path("${stateDir}/qBittorrent/config/qBittorrent.conf")
    path.parent.mkdir(parents=True, exist_ok=True)
    data = configparser.RawConfigParser(delimiters=("=",), strict=False)
    data.optionxform = str
    if path.exists():
        data.read(path)
    for section, values in json.loads(Path("${settings}").read_text()).items():
        if not data.has_section(section):
            data.add_section(section)
        data[section].update(values)
    # Defaults apply only to a new profile. Other preferences and torrents persist.
    data["BitTorrent"].setdefault(r"Session\DefaultSavePath", "${dataDirectory}/qbittorrent/downloads")
    data["BitTorrent"].setdefault(r"Session\TempPath", "${dataDirectory}/qbittorrent/incomplete")
    data["BitTorrent"].setdefault(r"Session\TempPathEnabled", "true")
    password = Path(os.environ["CREDENTIALS_DIRECTORY"], "webui-password").read_text().strip()
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha512", password.encode(), salt, 100000, dklen=64)
    encoded = base64.b64encode(salt).decode() + ":" + base64.b64encode(digest).decode()
    data["Preferences"][r"WebUI\Password_PBKDF2"] = '"@ByteArray(' + encoded + ')"'
    # Secret material stays in the private runtime profile, never in argv/store.
    os.umask(0o077)
    temporary = path.with_suffix(".conf.tmp")
    with temporary.open("w") as output:
        data.write(output, space_around_delimiters=False)
    temporary.chmod(0o600)
    temporary.replace(path)
  '';
in
{
  options.infra.qbittorrentSilly.url = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Public HTTPS URL of qBittorrent silly, using the Deluge HTTP Basic login and application password.";
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = services.hasTag "applications/deluge";
          message = "applications/qbittorrent-silly requires applications/deluge on the same node for shared storage, credentials and VPN protection.";
        }
      ];
      sops.secrets."${instance}/webui-password" = {
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
        "d ${dataDirectory}/qbittorrent 2770 ${instance} ${mediaCfg.name} -"
        "d ${dataDirectory}/qbittorrent/downloads 2770 ${instance} ${mediaCfg.name} -"
        "d ${dataDirectory}/qbittorrent/incomplete 2770 ${instance} ${mediaCfg.name} -"
      ];
      systemd.services.${instance} = {
        description = "Independent qBittorrent instance in the Deluge provider VPN";
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
        environment.QT_QPA_PLATFORM = "offscreen";
        serviceConfig = {
          User = instance;
          Group = instance;
          SupplementaryGroups = [ mediaCfg.name ];
          StateDirectory = instance;
          StateDirectoryMode = "0700";
          WorkingDirectory = stateDir;
          LoadCredential = [ "webui-password:/run/secrets/${instance}/webui-password" ];
          ExecStartPre = "${pkgs.python3}/bin/python ${prepare}";
          ExecStart = "${pkgs.qbittorrent-nox}/bin/qbittorrent-nox --profile=${stateDir} --webui-port=${toString port} --torrenting-port=51414 --confirm-legal-notice";
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
          description = "qBittorrent silly WebUI relay";
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
