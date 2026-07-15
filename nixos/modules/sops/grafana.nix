{
  config,
  lib,
  services,
  ...
}:

{
  config = lib.mkIf (services.hasTag "grafana") {
    sops.secrets = {
      "grafana/password" = {
        sopsFile = config.infra.sops.secretsDirectory + "/grafana.json";
        key = "password";
      };
      "grafana/secret" = {
        sopsFile = config.infra.sops.secretsDirectory + "/grafana.json";
        key = "grafana_secret";
      };
    };

    infra.grafana = {
      passwordFile = "/run/secrets/grafana/password";
      grafanaSecretFile = "/run/secrets/grafana/secret";
    };
  };
}
