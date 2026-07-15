{ config, ... }:

let
  secretsDir = config.infra.sops.secretsDirectory;
in
{
  sops.secrets."wireguard/private-key" = {
    sopsFile = secretsDir + "/wireguard/${config.infra.nodeName}.json";
    key = "privateKey";
    mode = "0400";
  };

  infra.wireguard.privateKeyFile = config.sops.secrets."wireguard/private-key".path;
}
