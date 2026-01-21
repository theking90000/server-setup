{
  config,
  lib,
  services,
  ...
}:

with lib;

let
  # Définition de la structure d'une règle (Type Checking)
  aclRuleSubmodule = types.submodule {
    options = {
      port = mkOption { type = types.port; };
      proto = mkOption {
        type = types.enum [
          "tcp"
          "udp"
        ];
        default = "tcp";
      };

      # On accepte soit des Tags (magique), soit des IPs brutes (manuel)
      allowedTags = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      allowedIps = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };

      trustLocalRoot = mkOption {
        type = types.bool;
        default = true;
      };
      description = mkOption {
        type = types.str;
        default = "";
      };
    };
  };

  cfg = config.infra.security.acls;
in
{
  # 1. L'INTERFACE (Ce que l'utilisateur voit)
  options.infra.security.acls = mkOption {
    type = types.listOf aclRuleSubmodule;
    default = [ ];
    description = "Liste déclarative des ouvertures de ports sécurisées via Whitelist.";
  };

  # 2. L'IMPLÉMENTATION (La mécanique interne)
  config = mkIf (cfg != [ ]) {

    networking.firewall.extraInputRules = concatMapStrings (
      rule:
      let
        # On résout les Tags en IPs grâce à vos utils
        resolvedIpsFromTags = concatMap (tag: services.getVpnIpsByTag tag) rule.allowedTags;

        # On fusionne avec les IPs manuelles
        finalIps = rule.allowedIps ++ resolvedIpsFromTags;

        # Conversion en Set Nftables
        ipSet = concatStringsSep ", " finalIps;
        portStr = toString rule.port;
      in
      ''
        # --- ACL: ${rule.description} (Port ${portStr}/${rule.proto}) ---
        ${optionalString (finalIps != [ ]) ''
          ip saddr { ${ipSet} } ${rule.proto} dport ${portStr} accept comment "ACL: ${rule.description}"
        ''}

        ${optionalString rule.trustLocalRoot ''
          iifname "lo" ${rule.proto} dport ${portStr} meta skuid "root" accept comment "ACL: ${rule.description} (Local Root Trust)"
        ''}

        # Drop explicite par défaut sur ce port
        ${rule.proto} dport ${portStr} drop comment "ACL: ${rule.description} (Default Drop)"
      ''
    ) cfg;
  };
}
