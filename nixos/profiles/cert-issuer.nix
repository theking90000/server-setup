{
  config,
  pkgs,
  lib,
  ...
}:

let
  ssh = import ../ssh-vars.nix;

  cfg = config.profile.certs;
in
{
  options.profile.certs = {
    email = lib.mkOption {
      type = lib.types.str;
      description = "Email ACME.";
    };

    issueDomains = lib.mkOption {
      description = "Liste des domaines à gérer.";
      default = [ ];
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            domain = lib.mkOption { type = lib.types.str; };
            dnsProvider = lib.mkOption { type = lib.types.str; };
            credentialsFile = lib.mkOption { type = lib.types.str; };
          };
        }
      );
    };
  };

  config = lib.mkIf (cfg.issueDomains != [ ]) {

    # 1. Création de l'utilisateur dédié
    users.users.cert-syncer = {
      isNormalUser = true;
      # Pas de shell interactif, c'est un compte de service
      # shell = "${pkgs.shadow}/bin/nologin";
      # On force le groupe pour que les fichiers ACME lui appartiennent
      group = "cert-syncer";
      # On revient à la méthode standard
      openssh.authorizedKeys.keys = [
        ''command="${pkgs.rrsync}/bin/rrsync /var/lib/acme/",restrict ${ssh.certSyncPublicKey}''
      ];
      #openssh.authorizedKeys.keys = [ "/var/lib/secrets/common-key.pub" ];
    };

    users.groups.cert-syncer = { };

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
      defaults.email = cfg.email;

      certs = lib.listToAttrs (
        map (certOpts: {
          name = lib.replaceStrings [ "*" ] [ "_" ] certOpts.domain;
          value = {
            dnsProvider = certOpts.dnsProvider;
            credentialsFile = certOpts.credentialsFile;

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
        }) cfg.issueDomains
      );
    };

    profile.backup.paths = [ "/var/lib/acme" ];
  };
}
