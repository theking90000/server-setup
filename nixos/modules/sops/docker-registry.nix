{
  config,
  lib,
  services,
  ...
}:

{
  config = lib.mkIf (services.hasTag "applications/docker-registry") {
    sops.secrets."docker-registry/accounts" = {
      sopsFile = config.infra.sops.secretsDirectory + "/docker-registry.json";
      key = "accounts";
    };

    infra.dockerRegistry.accountsFile = "/run/secrets/docker-registry/accounts";
  };
}
