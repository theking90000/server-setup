# -------------------------------------------------------------------------
# www.nix — Serveur de fichiers statiques (hébergement web)
#
# Déploie un serveur nginx dédié écoutant sur le VPN, servant :
#   1. Un paquet Nix (site statique compilé) à la racine
#   2. Un fallback vers /var/lib/www/public pour les gros fichiers
#      gérés manuellement (zip, images, vidéos…)
#
# Les deux sources sont optionnelles. Si seul publicDir est défini,
# le dossier est servi directement avec autoindex.
#
# Tags requis : `applications/www`
# -------------------------------------------------------------------------
{
  config,
  lib,
  pkgs,
  services,
  ops,
  ...
}:

let
  tag = "applications/www";
  enabled = services.hasTag tag;
  cfg = config.infra.www;

  nginxConfig = pkgs.writeText "www-nginx.conf" (
    ''
      daemon off;
      worker_processes 1;
      error_log stderr;
      pid /run/www/nginx.pid;
      events { worker_connections 1024; }
      http {
        access_log off;
        include ${pkgs.nginx}/conf/mime.types;
        default_type application/octet-stream;

        server_tokens off;

        server {
          listen ${services.getVpnIp}:${toString cfg.port};
          server_name _;
    ''
    + (
      if cfg.package != null then
        ''
          root ${cfg.package};

          location / {
            autoindex off;
            try_files $uri $uri/ @public;
          }

          location @public {
            root ${cfg.publicDir};
            try_files $uri $uri/ =404;
            autoindex on;
          }
        ''
      else
        ''
          root ${cfg.publicDir};

          location / {
            try_files $uri $uri/ =404;
            autoindex on;
          }
        ''
    )
    + ''
        }
      }
    ''
  );
in
{
  options.infra.www = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique du site.";
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Paquet Nix à servir à la racine (site statique compilé).";
    };

    publicDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/www/public";
      description = "Dossier de fichiers publics (fallback pour les gros fichiers).";
    };

    port = lib.mkOption {
      type = lib.types.int;
      default = 8090;
      description = "Port d'écoute sur le VPN.";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }

    (lib.mkIf enabled {
      users.users.www-data = {
        isSystemUser = true;
        group = "www-data";
      };
      users.groups.www-data = { };

      systemd.tmpfiles.rules = [
        "d ${cfg.publicDir} 0755 www-data www-data -"
      ];

      systemd.services.www = {
        description = "Static file server (www)";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          ExecStart = "${pkgs.nginx}/bin/nginx -g 'error_log stderr;' -c ${nginxConfig}";
          ExecReload = "${pkgs.nginx}/bin/nginx -g 'error_log stderr;' -s reload -c ${nginxConfig}";
          RuntimeDirectory = "www";
          User = "www-data";
          Group = "www-data";
          Restart = "on-failure";
          RestartSec = "5s";
          NoNewPrivileges = true;
        };
      };

      infra.security.acls = [
        {
          port = cfg.port;
          allowedTags = [ "web-server" ];
          description = "WWW static files";
        }
      ];
    })

    (lib.mkIf (cfg.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."www" = {
        url = cfg.url;
        backend = map (ip: "${ip}:${toString cfg.port}") (services.getVpnIpsByTag tag);
      };
    })
  ];
}
