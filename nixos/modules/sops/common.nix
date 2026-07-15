{
  config,
  lib,
  ...
}:

let
  cfg = config.infra.sops;
in
{
  options.infra.sops = {
    secretsDirectory = lib.mkOption {
      type = lib.types.path;
      description = "Dossier privé contenant les fichiers JSON chiffrés avec SOPS.";
    };

    certSyncerPublicKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Fichier contenant la clé publique SSH du cert-syncer.";
    };
  };

  config = {
    sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    assertions = [
      {
        assertion = config.infra.acme.domains == [ ] || cfg.certSyncerPublicKeyFile != null;
        message = "infra.sops.certSyncerPublicKeyFile is required when ACME domains are configured.";
      }
    ];
  };
}
