{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.profile.certs;
in
{

  options.profile.certs = {
    masterIp = lib.mkOption { type = lib.types.str; };

    syncDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Liste des domaines à récupérer du maître.";
    };
  };

  config = lib.mkIf (cfg.syncDomains != [ ]) {
    users.groups.cert-syncer = { };

    # Create ACME user if not already present
    users.users.acme = {
      home = "/var/lib/acme";
      createHome = true;
      homeMode = "755";
      group = "acme";
      isSystemUser = true;
    };

    users.groups.acme = { };

    systemd.services.sync-certs = {
      description = "Récupérer les certificats depuis le maître";
      path = [
        pkgs.rsync
        pkgs.openssh
      ];
      serviceConfig.Type = "oneshot";
      serviceConfig.User = "acme";
      serviceConfig.Group = "acme";

      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig.LoadCredential = [ "ssh-key:/var/lib/secrets/common-key" ];

      script = ''
        # On boucle sur chaque domaine demandé
        ${lib.concatMapStrings (domain: ''
          echo "Syncing ${domain}..."
            rsync -avz --chmod=D750,F640 \
            -e "ssh -i $CREDENTIALS_DIRECTORY/ssh-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
            cert-syncer@${cfg.masterIp}:${domain}/ \
            /var/lib/acme/${domain}/
        '') cfg.syncDomains}

        # TODO: Reload services if needed?
      '';
    };

    systemd.timers.sync-certs = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "02:00:00";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };
  };

}
