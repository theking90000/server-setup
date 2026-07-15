{
  config,
  lib,
  services,
  ...
}:

let
  cfg = config.infra.sops;
  isIssuer = services.hasTag "acme-issuer";
  secret = file: key: {
    sopsFile = cfg.secretsDirectory + "/${file}.json";
    inherit key;
  };
in
{
  config = {
    sops.secrets = {
      "acme/syncer-private-key" = lib.mkIf (!isIssuer) (
        secret "acme-syncer" "privateKey" // { mode = "0400"; }
      );
      "acme/dns-credentials" = lib.mkIf isIssuer (
        secret "acme" "dnsCredentials"
        // {
          owner = "acme";
          group = "acme";
        }
      );
    };

    infra.acme = {
      certSyncerPrivateKeyFile = "/run/secrets/acme/syncer-private-key";
      certSyncerPublicKey =
        if cfg.certSyncerPublicKeyFile == null then null else builtins.readFile cfg.certSyncerPublicKeyFile;
      dnsCredentialsFile = "/run/secrets/acme/dns-credentials";
    };
  };
}
