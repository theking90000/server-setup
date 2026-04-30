# -------------------------------------------------------------------------
# ssh.nix — Configuration du serveur OpenSSH
#
# Active le daemon SSH sur le port 22, interdit l'authentification par
# mot de passe pour root, et déploie la clé publique SSH du noeud
# dans les authorized_keys de root.
#
# La clé publique est lue depuis l'option `infra.nodes.<name>.sshPublicKey`
# (fournie par le repo privé, typiquement générée par export-ssh-key.sh).
# -------------------------------------------------------------------------
{ config, lib, ... }:

let
  nodeName = config.infra.nodeName;
  me = config.infra.nodes.${nodeName};
in
{
  services.openssh = {
    enable = true;

    openFirewall = true;

    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  networking.firewall.allowedTCPPorts = [ 22 ];

  users.users.root.openssh.authorizedKeys.keys = lib.mkIf (me.sshPublicKey or null != null) [
    me.sshPublicKey
  ];
}
