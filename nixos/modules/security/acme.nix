{
  config,
  pkgs,
  lib,
  services,
  ops,
  ...
}:

let
  cfg = config.infra.acme;

  privateSSHKey = builtins.readFile ../../../.secrets/syncer.key;
  publicSSHKey = builtins.readFile ../../../.secrets/syncer.key.pub;

  issuer = services.hasTag "acme-issuer";

  issuers = services.getHostsByTag "acme-issuer";

  acmeConfig = (import ../../../config/acme/acme.nix);

  getVal = local: global: if local != null then local else global;
in
{
  options.infra.acme = {
    email = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    domains = lib.mkOption {
      default = [ ];
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            domain = lib.mkOption { type = lib.types.str; };
            dnsProvider = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            credentialsFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
          };
        }
      );
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.domains != [ ]) {
      users.groups.cert-syncer = { };

      users.users.acme = {
        home = "/var/lib/acme";
        createHome = true;
        homeMode = "755";
        group = "acme";
        isSystemUser = true;
      };

      users.groups.acme = { };
    })
    (lib.mkIf (issuer && cfg.domains != [ ]) {
      deployment.keys = ops.mkSecretKeys "acme" acmeConfig [ "dnsCredentials" ];

      users.users.cert-syncer = {
        isNormalUser = true;
        # Pas de shell interactif, c'est un compte de service
        # shell = "${pkgs.shadow}/bin/nologin";
        # On force le groupe pour que les fichiers ACME lui appartiennent
        group = "cert-syncer";
        # On revient à la méthode standard
        openssh.authorizedKeys.keys = [
          ''command="${pkgs.rrsync}/bin/rrsync /var/lib/acme/",restrict ${publicSSHKey}''
        ];
        #openssh.authorizedKeys.keys = [ "/var/lib/secrets/common-key.pub" ];
      };

      # 2. Configuration SSHD (Côté Serveur)
      services.openssh.extraConfig = ''
        Match User cert-syncer
            # On interdit tout sauf l'authentification par clé
            PasswordAuthentication no
            PubkeyAuthentication yes

            # AuthorizedKeysFile /var/lib/secrets/common-key.pub
            # Optionnel : Restreindre aux commandes rsync (plus complexe à setup, on laisse ouvert pour l'instant)
            # ForceCommand ${pkgs.rrsync}/bin/rrsync /var/lib/acme/
      '';

      # 3. Configuration ACME
      security.acme = {
        acceptTerms = true;
        defaults.email = getVal cfg.email acmeConfig.email;

        certs = lib.listToAttrs (
          map (certOpts: {
            name = lib.replaceStrings [ "*" ] [ "_" ] certOpts.domain;
            value = {
              dnsProvider = getVal certOpts.dnsProvider acmeConfig.dnsProvider;
              credentialsFile = getVal certOpts.credentialsFile "/var/lib/secrets/acme/dnsCredentials";

              # C'est l'utilisateur cert-syncer qui sera propriétaire des fichiers !
              group = "cert-syncer";

              domain =
                if (lib.hasPrefix "*." certOpts.domain) then
                  (lib.removePrefix "*." certOpts.domain)
                else
                  certOpts.domain;
              # Logique wildcard
              extraDomainNames = lib.optional (lib.hasPrefix "*." certOpts.domain) (certOpts.domain);
            };
          }) cfg.domains
        );
      };

      # profile.backup.paths = [ "/var/lib/acme" ];
    })
    (lib.mkIf (!issuer && cfg.domains != [ ] && issuers != [ ]) {
      deployment.keys."syncer.key" = {
        text = privateSSHKey;
        destDir = "/var/lib/secrets";
        user = "root";
        group = "root";
        permissions = "0400";
        name = "syncer.key";
      };

      systemd.services."sync-cert@" = {
        description = "Récupérer les certificats pour %i depuis le(s) issuer(s)";
        path = [
          pkgs.rsync
          pkgs.openssh
        ];
        serviceConfig.Type = "oneshot";
        serviceConfig.User = "acme";
        serviceConfig.Group = "acme";
        serviceConfig.LoadCredential = [ "ssh-key:/var/lib/secrets/syncer.key" ];

        scriptArgs = "%i";

        script = ''
          DOMAIN="$1" # %i contains the instance name (domain)
          ISSUERS="${lib.concatStringsSep " " issuers}"

          # Ensure destination directory exists
          mkdir -p "/var/lib/acme/$DOMAIN"

          for IP in $ISSUERS; do
            echo "Attempting to sync $DOMAIN from $IP..."
            if rsync -avz --chmod=D750,F640 \
              -e "ssh -i $CREDENTIALS_DIRECTORY/ssh-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10" \
              "cert-syncer@$IP:$DOMAIN/" \
              "/var/lib/acme/$DOMAIN/"; then
              echo "Successfully synced from $IP"
              exit 0
            else
              echo "Failed to sync from $IP"
              fi
            done

          echo "All sync attempts failed for $DOMAIN"
          exit 1
        '';
      };

      systemd.timers."sync-cert@" = {
        timerConfig = {
          OnBootSec = "1m";
          OnCalendar = "02:00:00";
          Persistent = true;
          # RandomizedDelaySec = "10m";
        };
      };

      # Activate the timer for each domain
      systemd.targets.timers.wants = map (
        d: "sync-cert@${lib.replaceStrings [ "*" ] [ "_" ] d.domain}.timer"
      ) cfg.domains;
    })
  ];
}
