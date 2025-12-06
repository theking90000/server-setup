{
  config,
  pkgs,
  lib,
  ...
}:

let
  wg = import ../wg-peers.nix;

  cfg = config.profile.dockerRegistry;
in
{
  options.profile.dockerRegistry = {
    enable = lib.mkEnableOption "Activer Docker-Registry sur ce serveur";
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = wg.wgIp;
      description = "L'IP sur laquelle Docker-Registry écoutera.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.docker-registry.serviceConfig = {
      RuntimeDirectory = "docker-registry";

      # La syntaxe est : "ID-DANS-LE-SERVICE : CHEMIN-REEL-SUR-LE-HOST"
      # LoadCredentials = [ "registry-auth:/var/lib/secrets/docker-registry-password" ];

      # 2. Le script magique qui s'exécute juste AVANT le lancement du registre
      # Il prend le secret en lecture seule et le copie dans la zone inscriptible de l'app
      ExecStartPre = [
        (
          "+"
          + pkgs.writeShellScript "setup-registry-auth-bruteforce" ''
            # 1. On définit les chemins
            SOURCE="/var/lib/secrets/docker-registry-password"
            DEST_DIR="/run/docker-registry/auth"
            DEST_FILE="$DEST_DIR/registry-auth" # Nom arbitraire que l'app lira

            echo "DEBUG ROOT: Copie de $SOURCE vers $DEST_FILE"

            # 2. Vérification que la source existe (Root voit tout)
            if [ ! -f "$SOURCE" ]; then
              echo "ERREUR FATALE: Le fichier secret $SOURCE est introuvable sur le disque !"
              exit 1
            fi

            # 3. Création du dossier de destination
            mkdir -p "$DEST_DIR"

            # 4. Copie brutale
            cp "$SOURCE" "$DEST_FILE"

            # 5. On donne le butin à l'utilisateur 'docker-registry'
            # (C'est crucial car le service principal tournera sous cet user)
            chown -R docker-registry:docker-registry "/run/docker-registry"
            chmod 600 "$DEST_FILE"

            echo "DEBUG ROOT: Succès. Permissions appliquées."
          ''
        )
      ];
    };

    services.dockerRegistry = {
      enable = true;
      port = 5000;
      listenAddress = cfg.listenAddress;

      storagePath = "/var/lib/docker-registry";

      enableDelete = true;
      enableGarbageCollect = true;

      extraConfig = {
        auth = {
          htpasswd = {
            realm = "Registry";
            # IMPORTANT : On pointe maintenant vers la COPIE dans le dossier Runtime
            # (et non plus vers /run/credentials/...)
            #path = "/run/credentials/docker-registry.service/registry-auth";
            path = "/run/docker-registry/auth/registry-auth";
          };
        };

        http = {
          debug = {
            # On écoute sur le port 5001
            addr = "${cfg.listenAddress}:5001";
            prometheus = {
              enabled = true;
              path = "/metrics";
            };
          };
        };
      };
    };

    profile.backup.paths = [ "/var/lib/docker-registry" ];

    # Ouverture du port pour Docker-Registry (via VPN uniquement)
    networking.firewall.interfaces.wg0.allowedTCPPorts = [
      5000
      5001
    ];
  };
}
