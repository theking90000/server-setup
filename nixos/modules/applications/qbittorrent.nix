# -------------------------------------------------------------------------
# qbittorrent.nix — Client BitTorrent isolé derrière un VPN tiers
#
# qBittorrent tourne dans un network namespace dédié dont la SEULE route
# par défaut est une interface WireGuard vers un provider VPN externe
# (Mullvad, Proton, AirVPN…). Kill switch structurel : si le tunnel tombe,
# le netns n'a aucun autre chemin vers Internet.
#
#   hôte                                netns "qbittorrent"
#   ────────────────────────────        ──────────────────────────────
#   uplink ── UDP chiffré ──────────►   wg-qbt (default route)
#   veth-qbt 10.200.0.1/30 ◄──veth──►   veth-qbt-ns 10.200.0.2/30
#   wg0 (mesh) ── socket-proxyd ────►   WebUI :8080
#
# L'interface wg-qbt est créée et configurée dans le ns hôte (résolution
# DNS de l'Endpoint via l'hôte, socket UDP chiffré côté hôte) puis
# déplacée dans le netns : seul le trafic en clair vit dans le netns.
# Le veth ne porte aucune route par défaut, il sert uniquement à exposer
# la WebUI, relayée sur l'IP wg0 du nœud par systemd-socket-proxyd.
#
# La conf du provider est la .conf wg-quick brute, collée telle quelle
# dans le repo privé : secrets/qbittorrent.json, clé "wgConf".
# Address/DNS/MTU en sont extraits à l'exécution, le reste part dans
# `wg setconf` via `wg-quick strip`.
#
# Notes d'exploitation :
#   - premier démarrage : mot de passe WebUI temporaire dans
#     `journalctl -u qbittorrent` ;
#   - la WebUI écoute sur toutes les interfaces du netns, wg-qbt inclus ;
#     dans les préférences WebUI, fixer l'adresse d'écoute à 10.200.0.2
#     si le provider autorise du trafic entrant ;
#   - `systemctl restart qbittorrent-netns` recrée le netns : relancer
#     ensuite qbittorrent à la main (la rotation SOPS le fait déjà).
#
# Tags requis : `applications/qbittorrent`
# -------------------------------------------------------------------------
{
  config,
  lib,
  pkgs,
  services,
  ...
}:

let
  cfg = config.infra.qbittorrent;
  tag = "applications/qbittorrent";
  enabled = services.hasTag tag;

  netns = "qbittorrent";
  wgIf = "wg-qbt";
  # ponytail: /30 fixe, à rendre configurable seulement si un déploiement
  # utilise déjà 10.200.0.0/30
  hostVethIp = "10.200.0.1";
  nsVethIp = "10.200.0.2";
  wgConfPath = "/run/secrets/qbittorrent/wg.conf";
  profileDir = "/var/lib/qBittorrent";

  cleanupScript = ''
    ip netns delete ${netns} 2>/dev/null || true
    # une interface wireguard revient dans son ns de naissance à la
    # destruction du netns : suppression explicite
    ip link delete ${wgIf} 2>/dev/null || true
    ip link delete veth-qbt 2>/dev/null || true
    rm -rf /etc/netns/${netns}
  '';
in
{
  options.infra.qbittorrent = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique de la WebUI (ex: https://qbt.example.com).";
    };

    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port de la WebUI, dans le netns et sur l'IP wg0 du nœud.";
    };

    torrentingPort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = "Port d'écoute BitTorrent (port forwardé par le provider VPN).";
    };
  };

  config = lib.mkMerge [
    # Module contract
    { infra.registeredTags = [ tag ]; }

    # Local configuration
    (lib.mkIf enabled {
      sops.secrets."qbittorrent/wg.conf" = {
        sopsFile = config.infra.sops.secretsDirectory + "/qbittorrent.json";
        key = "wgConf";
        mode = "0400";
        restartUnits = [
          "qbittorrent-netns.service"
          "qbittorrent.service"
        ];
      };

      systemd.services.qbittorrent-netns = {
        description = "Netns + WireGuard provider pour qBittorrent (kill switch)";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        path = [
          pkgs.iproute2
          pkgs.wireguard-tools
          pkgs.gawk
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          conf=${wgConfPath}

          get() {
            awk -F= -v key="$1" '
              { k = $1; sub(/^[ \t]+/, "", k); sub(/[ \t]+$/, "", k) }
              tolower(k) == key { v = $2; gsub(/,/, " ", v); print v }
            ' "$conf"
          }

          ${cleanupScript}

          ip netns add ${netns}
          ip -n ${netns} link set lo up

          # créé et configuré côté hôte (DNS de l'Endpoint résolu ici,
          # socket UDP chiffré ancré dans le ns hôte), puis déplacé :
          # la config wireguard survit au changement de namespace
          ip link add ${wgIf} type wireguard
          wg setconf ${wgIf} <(wg-quick strip "$conf")
          ip link set ${wgIf} netns ${netns}

          for addr in $(get address); do
            ip -n ${netns} addr add "$addr" dev ${wgIf}
          done
          mtu=$(get mtu)
          if [ -n "$mtu" ]; then
            ip -n ${netns} link set ${wgIf} mtu $mtu
          fi
          ip -n ${netns} link set ${wgIf} up

          # seule route par défaut du netns : le tunnel (kill switch)
          ip -n ${netns} route add default dev ${wgIf}
          ip -n ${netns} -6 route add default dev ${wgIf} 2>/dev/null || true

          # veth réservé à la WebUI : pas de route par défaut, pas de NAT
          ip link add veth-qbt type veth peer name veth-qbt-ns
          ip link set veth-qbt-ns netns ${netns}
          ip addr add ${hostVethIp}/30 dev veth-qbt
          ip link set veth-qbt up
          ip -n ${netns} addr add ${nsVethIp}/30 dev veth-qbt-ns
          ip -n ${netns} link set veth-qbt-ns up

          # DNS du provider, sinon résolveur public via le tunnel
          mkdir -p /etc/netns/${netns}
          dns=$(get dns)
          for d in ''${dns:-9.9.9.9}; do
            echo "nameserver $d"
          done > /etc/netns/${netns}/resolv.conf
        '';
        postStop = cleanupScript;
      };

      services.qbittorrent = {
        enable = true;
        openFirewall = false;
        webuiPort = cfg.webuiPort;
        torrentingPort = cfg.torrentingPort;
      };

      systemd.services.qbittorrent = {
        bindsTo = [ "qbittorrent-netns.service" ];
        after = [ "qbittorrent-netns.service" ];
        serviceConfig = {
          NetworkNamespacePath = "/run/netns/${netns}";
          BindReadOnlyPaths = [ "/etc/netns/${netns}/resolv.conf:/etc/resolv.conf" ];
          # incompatible avec l'entrée dans un netns possédé par le user ns initial
          PrivateUsers = lib.mkForce false;
        };
      };

      # Relais WebUI : IP wg0 du nœud -> veth du netns
      systemd.sockets.qbittorrent-webui = {
        description = "Socket WebUI qBittorrent sur le mesh";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "${services.getVpnIp}:${toString cfg.webuiPort}" ];
        # wg0 peut monter après sockets.target
        socketConfig.FreeBind = true;
      };

      systemd.services.qbittorrent-webui = {
        description = "Proxy WebUI qBittorrent (wg0 -> netns)";
        requires = [ "qbittorrent-netns.service" ];
        after = [ "qbittorrent-netns.service" ];
        serviceConfig.ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${nsVethIp}:${toString cfg.webuiPort}";
      };

      infra.security.acls = [
        {
          port = cfg.webuiPort;
          allowedTags = [ "web-server" ];
          description = "qBittorrent WebUI";
        }
      ];

      infra.backup.paths = [ profileDir ];
    })

    # Fleet-wide contributions
    (lib.mkIf (services.getVpnIpsByTag tag != [ ] && cfg.url != null) {
      infra.ingress.qbittorrent = {
        url = cfg.url;
        backend = map (ip: "${ip}:${toString cfg.webuiPort}") (services.getVpnIpsByTag tag);
      };
    })
  ];
}
