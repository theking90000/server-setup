{
  config,
  lib,
  pkgs,
  services,
  ...
}:

let
  cfg = config.infra.hermes-agent;
  tag = "applications/hermes-agent";
  enabled = services.hasTag tag;

  containerDir = "/var/lib/hermes-agent";
  hostIp = "10.99.0.1";
  containerIp = "10.99.0.2";
  prefixLength = 30;
  vethHost = "ve-hermes-agent";
in
{
  options.infra.hermes-agent = {
    memoryLimit = lib.mkOption {
      type = lib.types.str;
      default = "2G";
      description = "Limite mémoire du conteneur (systemd MemoryMax).";
    };
    cpuQuota = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "200%";
      description = "Quota CPU du conteneur (systemd CPUQuota). null = pas de limite.";
    };
    allowedPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 53 80 443 ];
      description = ''
        Ports sortants autorisés depuis le conteneur vers internet.
        Liste vide = tous les ports.
      '';
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }

    (lib.mkIf enabled {
      systemd.services.hermes-agent-init = {
        description = "Initialize Hermes Agent Debian Container";
        wantedBy = [ "multi-user.target" ];
        before = [ "hermes-agent.service" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        path = with pkgs; [ debootstrap systemd curl ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          if [ ! -f "${containerDir}/etc/debian_version" ]; then
            echo "Bootstrapping Debian Trixie container..."
            ${pkgs.debootstrap}/bin/debootstrap \
              --include=systemd,dbus,apt,curl,git,python3,python3-pip,sudo \
              trixie "${containerDir}" \
              http://deb.debian.org/debian

            echo "Creating hermes user with root (sudo) access..."
            ${pkgs.systemd}/bin/systemd-nspawn -D "${containerDir}" \
              /usr/sbin/useradd -m -s /bin/bash -G sudo hermes
            echo "hermes ALL=(ALL) NOPASSWD:ALL" \
              > "${containerDir}/etc/sudoers.d/hermes"
            chmod 440 "${containerDir}/etc/sudoers.d/hermes"

            echo "Configuring container network..."
            mkdir -p "${containerDir}/etc/systemd/network"
            cat > "${containerDir}/etc/systemd/network/80-host0.network" << 'NETEOF'
[Match]
Name=host0

[Network]
Address=${containerIp}/${toString prefixLength}
Gateway=${hostIp}
DNS=1.1.1.1
DNS=1.0.0.1
NETEOF

            echo "Enabling systemd-networkd in container..."
            ${pkgs.systemd}/bin/systemd-nspawn -D "${containerDir}" \
              /usr/bin/systemctl enable systemd-networkd

            echo "Setting up DNS for install step..."
            echo "nameserver 1.1.1.1" > "${containerDir}/etc/resolv.conf"
            echo "nameserver 1.0.0.1" >> "${containerDir}/etc/resolv.conf"

            echo "Installing hermes-agent..."
            ${pkgs.systemd}/bin/systemd-nspawn -D "${containerDir}" \
              /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
              /usr/bin/bash -c '/usr/bin/curl -fsSL https://hermes-agent.nousresearch.com/install.sh | /usr/bin/bash'

            echo "Hermes agent container initialized."
          else
            echo "Hermes agent container already exists, skipping bootstrap."
          fi
        '';
      };

      systemd.nspawn.hermes-agent = {
        execConfig = {
          Boot = true;
          ProcessTwo = true;
          PrivateUsers = "pick";
          NoNewPrivileges = true;
          SystemCallFilter = "@system-service";
        };
        networkConfig = {
          VirtualEthernet = true;
        };
      };

      systemd.services.hermes-agent = {
        description = "Hermes Agent Container";
        wantedBy = [ "multi-user.target" ];
        after = [ "hermes-agent-init.service" ];
        requires = [ "hermes-agent-init.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.systemd}/bin/systemd-nspawn --boot --directory=${containerDir} --keep-unit --link-journal=try-guest --settings=override --machine=hermes-agent";
          ExecStartPost = "-${pkgs.iproute2}/bin/ip addr add ${hostIp}/${toString prefixLength} dev ${vethHost}";
          ExecStop = "${pkgs.systemd}/bin/machinectl poweroff hermes-agent";
          Type = "simple";
          KillMode = "process";
          MemoryMax = cfg.memoryLimit;
        } // lib.optionalAttrs (cfg.cpuQuota != null) {
          CPUQuota = cfg.cpuQuota;
        };
      };

      networking.nat = {
        enable = true;
        internalInterfaces = [ vethHost ];
      };

      networking.firewall.extraForwardRules = lib.mkBefore (''
        # Hermes-agent: block access to VPN mesh (10.100.0.0/16)
        iifname "${vethHost}" ip daddr 10.100.0.0/16 drop comment "hermes-agent: block VPN"

        # Hermes-agent: block access to private/LAN ranges
        iifname "${vethHost}" ip daddr 192.168.0.0/16 drop comment "hermes-agent: block LAN"
        iifname "${vethHost}" ip daddr 10.0.0.0/8 drop comment "hermes-agent: block private"
        iifname "${vethHost}" ip daddr 172.16.0.0/12 drop comment "hermes-agent: block private"
        iifname "${vethHost}" ip daddr 127.0.0.0/8 drop comment "hermes-agent: block loopback"
        iifname "${vethHost}" ip daddr 169.254.0.0/16 drop comment "hermes-agent: block link-local"
      '' + lib.optionalString (cfg.allowedPorts != []) ''
        # Hermes-agent: restrict outbound ports
        iifname "${vethHost}" tcp dport != { ${
          lib.concatMapStringsSep ", " toString cfg.allowedPorts
        } } drop comment "hermes-agent: restrict TCP ports to allowed"
        iifname "${vethHost}" udp dport != { ${
          lib.concatMapStringsSep ", " toString cfg.allowedPorts
        } } drop comment "hermes-agent: restrict UDP ports to allowed"
      '');

      networking.firewall.extraInputRules = lib.mkBefore ''
        iifname "${vethHost}" drop comment "hermes-agent: block container access to host"
      '';

      # TODO: future hermes-agent config
      #   options.infra.hermes-agent.config = lib.mkOption { ... };
      #
      # TODO: backup of hermes-agent state
      #   infra.backup.paths = [ "/var/lib/hermes-agent/home/hermes/.config/..." ];
    })
  ];
}
