{
  config,
  lib,
  pkgs,
  services,
  ...
}:
let
  cfg = config.infra.deluge;
  tag = "applications/deluge";
  enabled = services.hasTag tag;
  present = services.getHostsByTag tag != [ ];
  netns = cfg.networkNamespace;
  webuiPorts = lib.concatStringsSep ", " (
    map toString (
      [ cfg.webuiPort ]
      ++ lib.optional (services.hasTag "applications/sonarr-silly") 8990
      ++ lib.optional (services.hasTag "applications/radarr-silly") 7879
      ++ lib.optional (services.hasTag "applications/prowlarr-silly") 9697
    )
  );
  stateDir = "/var/lib/deluge";
  configDir = "${stateDir}/config";
  package = pkgs.deluge-2_x.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      # ExtJS serializes the file field as "[object FileList]". Read the
      # selected File's name before the asynchronous form upload.
      substituteInPlace "$out/${pkgs.python3.sitePackages}/deluge/ui/web/js/deluge-all-debug.js" \
        --replace-fail 'onInstall: function (field, e) {' \
          'onInstall: function (field, e) { this.pluginFilename = this.form.getForm().findField("file").fileInput.dom.files[0].name;' \
        --replace-fail 'this.form.getForm().getFieldValues().file' \
          'this.pluginFilename'
    '';
  });
  sandbox = {
    User = "deluge";
    Group = "deluge";
    SupplementaryGroups = [ "deluge-media" ];
    StateDirectory = "deluge";
    StateDirectoryMode = "0700";
    WorkingDirectory = stateDir;
    NetworkNamespacePath = netns.path;
    BindReadOnlyPaths = [ "${netns.resolvConf}:/etc/resolv.conf" ];
    BindPaths = [
      stateDir
      cfg.dataDirectory
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
    NoNewPrivileges = true;
    PrivateUsers = false;
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
  prepareWeb = pkgs.writeText "deluge-prepare-web.py" ''
    import hashlib, json, os, secrets, time
    from pathlib import Path

    path = Path("${configDir}/web.conf")
    # Deluge stores a version object followed by a configuration object.
    version, data = {"file": 1, "format": 1}, {}
    if path.exists():
        text = path.read_text()
        decoder = json.JSONDecoder()
        version, offset = decoder.raw_decode(text.lstrip())
        data = json.loads(text.lstrip()[offset:])
    password = Path(os.environ["CREDENTIALS_DIRECTORY"], "webui-password").read_text().strip()
    salt = secrets.token_hex(20)
    data.update(interface="${netns.namespaceAddress}", port=${toString cfg.webuiPort},
                https=False, pwd_salt=salt,
                pwd_sha1=hashlib.sha1((salt + password).encode()).hexdigest(),
                sessions={}, default_daemon="local", first_login=False)
    path.write_text(json.dumps(version) + "\n" + json.dumps(data))
    os.chmod(path, 0o600)
    hosts = Path("${configDir}/hostlist.conf")
    # deluged creates its localclient credentials before its RPC listener.
    auth = Path("${configDir}/auth")
    for attempt in range(100):
        lines = auth.read_text().splitlines() if auth.exists() else []
        if any(line.startswith("localclient:") for line in lines):
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("Deluge localclient credentials were not created")
    for line in lines:
        if not line or line.startswith("#"):
            continue
        user, secret, level = line.split(":", 2)
        if user == "localclient":
            hosts.write_text(json.dumps({"file": 3, "format": 1}) + "\n" + json.dumps({
                "hosts": [["local", "127.0.0.1", 58846, user, secret]]}))
            os.chmod(hosts, 0o600)
            break
    else:
        raise RuntimeError("Deluge localclient credentials are missing")
  '';
in
{
  options.infra.deluge = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public HTTPS URL, protected by a dedicated HTTP Basic login.";
    };
    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 8112;
    };
    dataDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/srv/deluge-media";
      description = "Dedicated local storage shared with Sonarr VPN, excluding application state.";
    };
    networkNamespace = lib.mkOption {
      internal = true;
      readOnly = true;
      type = lib.types.attrsOf lib.types.str;
      default = config.infra.qbittorrent.networkNamespace;
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }

    (lib.mkIf enabled {
      assertions = [
        {
          assertion = services.hasTag "applications/qbittorrent";
          message = "applications/deluge requires applications/qbittorrent on the same node to share its provider VPN.";
        }
        {
          assertion = lib.hasPrefix "/srv/" cfg.dataDirectory && cfg.dataDirectory != "/srv/";
          message = "infra.deluge.dataDirectory must be a dedicated directory below /srv/.";
        }
      ];
      sops.secrets."deluge/webui-password" = {
        sopsFile = config.infra.sops.secretsDirectory + "/deluge.json";
        key = "webui_password";
        restartUnits = [ "deluge-web.service" ];
      };
      users.groups.deluge = { };
      users.groups.deluge-media = { };
      users.users.deluge = {
        isSystemUser = true;
        group = "deluge";
        home = stateDir;
      };
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDirectory} 2770 root deluge-media -"
        "d ${cfg.dataDirectory}/downloads 2770 deluge deluge-media -"
      ];
      # Only the host's root-owned relays may enter these WebUIs. Other
      # namespace applications can use them over loopback, not via the host.
      networking.nftables.tables.deluge-webui = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority 0; policy accept;
            oifname "veth-qbt" tcp dport { ${webuiPorts} } meta skuid != 0 reject
          }
        '';
      };
      systemd.services.deluge-vpn-guard = {
        description = "Protect Deluge and Servarr silly ports inside the shared VPN";
        bindsTo = [ netns.unit ];
        after = [ netns.unit ];
        partOf = [ netns.unit ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          NetworkNamespacePath = netns.path;
          ExecStart = "${pkgs.nftables}/bin/nft -f ${pkgs.writeText "deluge-webui.nft" ''
            table inet deluge_webui {
              chain input {
                type filter hook input priority -10; policy accept;
                iifname "lo" tcp dport { ${webuiPorts} } accept
                iifname "veth-qbt-ns" ip saddr ${netns.hostAddress} tcp dport { ${webuiPorts} } accept
                tcp dport { ${webuiPorts} } drop
              }
              chain output {
                type filter hook output priority -10; policy accept;
                oifname "veth-qbt-ns" ct state established,related accept
                oifname "veth-qbt-ns" meta skuid "deluge" reject
                ${lib.optionalString (services.hasTag "applications/sonarr-silly") ''
                  oifname "veth-qbt-ns" meta skuid "sonarr-silly" reject
                ''}
                ${lib.optionalString (services.hasTag "applications/radarr-silly") ''
                  oifname "veth-qbt-ns" meta skuid "radarr-silly" reject
                ''}
                ${lib.optionalString (services.hasTag "applications/prowlarr-silly") ''
                  oifname "veth-qbt-ns" meta skuid "prowlarr-silly" reject
                ''}
              }
            }
          ''}";
          ExecStop = "${pkgs.nftables}/bin/nft delete table inet deluge_webui";
        };
      };
      systemd.services.deluged = {
        description = "Deluge daemon in the provider VPN";
        wantedBy = [ "multi-user.target" ];
        requires = [ "deluge-vpn-guard.service" ];
        bindsTo = [ netns.unit ];
        after = [
          netns.unit
          "deluge-vpn-guard.service"
        ];
        # Restart consumers when the namespace is recreated, including a
        # SOPS rotation. BindsTo alone only stops them.
        partOf = [
          netns.unit
          "deluge-vpn-guard.service"
        ];
        serviceConfig = sandbox // {
          ExecStart = "${package}/bin/deluged -d -c ${configDir} -u 127.0.0.1";
        };
        preStart = ''
          mkdir -p ${configDir}
          if [ ! -e ${configDir}/core.conf ]; then
            cat > ${configDir}/core.conf <<'EOF'
          ${builtins.toJSON {
            download_location = "${cfg.dataDirectory}/downloads";
            allow_remote = false;
            daemon_port = 58846;
            outgoing_interface = "wg-qbt";
            enabled_plugins = [ "Label" ];
            upnp = false;
            natpmp = false;
          }}
          EOF
          fi
        '';
      };
      systemd.services.deluge-web = {
        description = "Deluge WebUI in the provider VPN";
        wantedBy = [ "multi-user.target" ];
        requires = [
          "deluged.service"
          "deluge-vpn-guard.service"
        ];
        bindsTo = [ netns.unit ];
        after = [
          netns.unit
          "deluge-vpn-guard.service"
          "deluged.service"
        ];
        partOf = [
          netns.unit
          "deluge-vpn-guard.service"
        ];
        serviceConfig = sandbox // {
          LoadCredential = [ "webui-password:/run/secrets/deluge/webui-password" ];
          ExecStartPre = "${pkgs.python3}/bin/python ${prepareWeb}";
          ExecStart = "${package}/bin/deluge-web -d -c ${configDir} -i ${netns.namespaceAddress} -p ${toString cfg.webuiPort}";
        };
      };
      systemd.sockets.deluge-webui = {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "${services.getVpnIp}:${toString cfg.webuiPort}" ];
        socketConfig.FreeBind = true;
      };
      systemd.services.deluge-webui = {
        requires = [ netns.unit ];
        after = [ netns.unit ];
        serviceConfig.ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${netns.namespaceAddress}:${toString cfg.webuiPort}";
      };
      infra.security.acls = [
        {
          port = cfg.webuiPort;
          allowedTags = [ "web-server" ];
          description = "Deluge WebUI relay";
        }
      ];
      infra.backup.paths = [ stateDir ];
    })

    (lib.mkIf (present && services.hasTag "web-server") {
      sops.secrets."deluge/proxy-htpasswd" = {
        sopsFile = config.infra.sops.secretsDirectory + "/deluge.json";
        key = "proxy_htpasswd";
        owner = "nginx";
      };
    })
    (lib.mkIf (present && cfg.url != null) {
      infra.ingress.deluge = {
        url = cfg.url;
        proxyTo = map (ip: "http://${ip}:${toString cfg.webuiPort}") (services.getVpnIpsByTag tag);
        routes.main.nginx.basicAuthFile = "/run/secrets/deluge/proxy-htpasswd";
      };
    })
  ];
}
