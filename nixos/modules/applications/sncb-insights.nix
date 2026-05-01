# -------------------------------------------------------------------------
# sncb-insights.nix — Belgian Rail Data / SNCB Insights
#
# Déploie le binaire sncb-insights (provenant du flake privé
# github:theking90000/belgian-rail-data) en deux modes :
#   1. --server : service HTTP écoutant sur l'IP VPN (port 9004),
#      activé uniquement si une URL publique est configurée.
#   2. --wake   : commande périodique exécutée toutes les heures
#      via un timer systemd.
#
# Tags requis : `applications/sncb-insights`
# -------------------------------------------------------------------------
{
  config,
  services,
  lib,
  pkgs,
  ...
}:

let
  tag = "applications/sncb-insights";
  dataDir = "/var/lib/sncb-insights";
  port = 9004;

  enabled = services.hasTag tag;

  pkg = config.infra.sncb-insights.package;

  sncb-insights-wrapper = pkgs.writeShellScriptBin "sncb-insights" ''
    cd ${dataDir} || exit 1
    exec ${lib.getExe pkg} "$@"
  '';
in
{
  options.infra.sncb-insights = {
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = if builtins.hasAttr "sncb-insights" pkgs then pkgs.sncb-insights else null;
      description = ''
        Paquet sncb-insights.
        Provient du flake privé https://github.com/theking90000/belgian-rail-data.
      '';
    };

    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique du service SNCB Insights (ex: https://sncb.example.com).";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }

    (lib.mkIf enabled {
      assertions = [
        {
          assertion = pkg != null;
          message = ''
            Le paquet 'pkgs.sncb-insights' est introuvable.

            Ajoutez ceci dans le flake.nix de votre dépôt privé :

              1. Dans inputs :
                 sncb-insights.url = "github:theking90000/belgian-rail-data";

              2. Dans outputs, ajoutez sncb-insights aux arguments :
                 { nixpkgs, nixpkgs-darwin, infra, colmena, sncb-insights, ... }:

              3. Dans colmena.meta.nixpkgs, ajoutez un overlay :
                 nixpkgs = import nixpkgs {
                   system = "x86_64-linux";
                   overlays = [
                     (final: prev: {
                       sncb-insights = sncb-insights.packages.x86_64-linux.sncb-insights;
                     })
                   ];
                 };
          '';
        }
      ];

      users.users.sncb-insights = {
        isSystemUser = true;
        group = "sncb-insights";
        home = dataDir;
        createHome = false;
      };

      users.groups.sncb-insights = { };

      infra.backup.paths = [ dataDir ];
    })

    # --- Wake timer (all nodes with the tag) ---
    (lib.mkIf (enabled && pkg != null) {
      environment.systemPackages = [ sncb-insights-wrapper ];

      systemd.timers.sncb-insights-wake = {
        description = "SNCB Insights periodic wake timer";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "hourly";
          Persistent = true;
        };
      };

      systemd.services.sncb-insights-wake = {
        description = "SNCB Insights wake command";
        after = [ "network.target" ];

        serviceConfig = {
          User = "sncb-insights";
          Group = "sncb-insights";
          StateDirectory = "sncb-insights";
          WorkingDirectory = dataDir;
          ExecStart = "${pkg}/bin/sncb-insights --wake";
          ProtectSystem = "strict";
          ProtectHome = true;
          NoNewPrivileges = true;
        };
      };
    })

    # --- Server mode (only if public URL is set) ---
    (lib.mkIf (enabled && pkg != null && config.infra.sncb-insights.url != null) {
      systemd.services.sncb-insights-server = {
        description = "SNCB Insights server";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        environment = {
          BIND_ADDRESS = "${services.getVpnIp}:${toString port}";
        };

        serviceConfig = {
          User = "sncb-insights";
          Group = "sncb-insights";
          StateDirectory = "sncb-insights";
          WorkingDirectory = dataDir;
          ExecStart = "${pkg}/bin/sncb-insights --server --port ${toString port}";
          Restart = "on-failure";
          RestartSec = "5s";
          ProtectSystem = "strict";
          ProtectHome = true;
          NoNewPrivileges = true;
        };
      };

      infra.security.acls = [
        {
          port = port;
          allowedTags = [ "web-server" ];
          description = "SNCB Insights";
        }
      ];
    })

    # --- Ingress (global: only if URL is set and at least one host has the tag) ---
    (lib.mkIf (config.infra.sncb-insights.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."sncb-insights" = {
        url = config.infra.sncb-insights.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);
      };
    })
  ];
}
