{
  config,
  lib,
  ...
}:

let
  mounts = config.infra.rcloneSync.mounts;
  mountedHere = lib.filterAttrs (
    _: mount: builtins.elem config.infra.nodeName mount.targetNodes
  ) mounts;
  sopsMounts = lib.filterAttrs (
    _: mount: mount.configContent == null && mount.configFile == null
  ) mounts;
  localSopsMounts = lib.filterAttrs (
    name: _: builtins.hasAttr name sopsMounts
  ) mountedHere;
in
{
  sops.secrets = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "rclone/${name}" {
      sopsFile = config.infra.sops.secretsDirectory + "/rclone-sync.json";
      key = name;
    }
  ) localSopsMounts;

  infra.rcloneSync.runtimeConfigFiles = lib.mapAttrs (
    name: _: "/run/secrets/rclone/${name}"
  ) sopsMounts;
}
