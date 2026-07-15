{
  config,
  lib,
  services,
  ...
}:

let
  secretsDir = config.infra.sops.secretsDirectory;
  has = tag: services.hasTag tag;
  localSsoClients = lib.filterAttrs (
    _: client: !client.public && (has "kanidm" || has client.serviceTag)
  ) config.infra.sso;
in
{
  sops.secrets = lib.mkMerge [
    {
      "kanidm/idm-admin-password" = lib.mkIf (has "kanidm" && config.infra.sso != { }) {
        sopsFile = secretsDir + "/kanidm.json";
        key = "idm_admin_password";
        owner = "kanidm";
        mode = "0400";
      };
    }
    (lib.mapAttrs' (
      name: _:
      lib.nameValuePair "sso/${name}-client-secret" {
        sopsFile = secretsDir + "/${name}.json";
        key = "oidc_client_secret";
        owner = if has "kanidm" then "kanidm" else "root";
        mode = "0400";
      }
    ) localSsoClients)
  ];
}
