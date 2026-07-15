{
  config,
  lib,
  services,
  ...
}:

let
  secret = key: {
    sopsFile = config.infra.sops.secretsDirectory + "/restic.json";
    inherit key;
  };
in
{
  config = lib.mkIf (services.hasTag "backup") {
    sops.secrets = {
      "restic/repository" = secret "repository";
      "restic/password" = secret "password";
      "restic/env" = secret "env";
    };

    infra.restic = {
      repositoryFile = "/run/secrets/restic/repository";
      passwordFile = "/run/secrets/restic/password";
      envFile = "/run/secrets/restic/env";
    };
  };
}
