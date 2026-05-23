# -------------------------------------------------------------------------
# jellyfin.nix — Serveur multimédia Jellyfin
#
# Déploie Jellyfin sur le port 8096. La configuration (bibliothèques,
# utilisateurs, etc.) n'est pas gérée de manière déclarative — l'utilisateur
# copie son ancienne installation Jellyfin dans /var/lib/jellyfin.
#
# Le service écoute sur 0.0.0.0 par défaut (pas de --serviceaddress natif
# dans le module NixOS jellyfin). La sécurité est assurée par les ACLs qui
# restreignent l'accès au port 8096 aux IPs VPN du tag web-server.
#
# Tags requis : `applications/jellyfin`
# -------------------------------------------------------------------------
{
  config,
  services,
  lib,
  ...
}:

let
  tag = "applications/jellyfin";
  port = 8096;
  enabled = services.hasTag tag;
in
{
  options.infra.jellyfin = {
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL publique de l'instance Jellyfin (ex: https://jellyfin.example.com).";
    };
  };

  config = lib.mkMerge [
    { infra.registeredTags = [ tag ]; }
    (lib.mkIf enabled {
      services.jellyfin = {
        enable = true;
        openFirewall = false;
      };

      infra.backup.paths = [ "/var/lib/jellyfin" ];

      infra.security.acls = [
        {
          port = port;
          allowedTags = [ "web-server" ];
          description = "Jellyfin";
        }
      ];
    })
    (lib.mkIf (config.infra.jellyfin.url != null && services.getVpnIpsByTag tag != [ ]) {
      infra.ingress."jellyfin" = {
        url = config.infra.jellyfin.url;
        backend = map (ip: "${ip}:${toString port}") (services.getVpnIpsByTag tag);
      };
    })
  ];
}
