{
  config,
  pkgs,
  lib,
  services,
  ...
}:

let
  enabled = services.hasTag "backup";

  backupName = "host-backup";
  backupCfg = config.services.restic.backups.${backupName};

  restoreScript = pkgs.writeShellScriptBin "restore-data" ''
    set -e

    # --- 1. CONFIGURATION PAR DÉFAUT ---
    TARGET_HOST="$HOSTNAME"
    TARGET_PATH="" # Si vide, on prendra tout

    # Chemins définis dans ta config NixOS (converti en string séparée par des espaces)
    NIX_PATHS="${toString backupCfg.paths}"

    # --- 2. PARSING DES ARGUMENTS ---
    function show_help {
      echo "Usage: restore-data [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  -h, --host <hostname>   Source du backup (Défaut: $HOSTNAME)"
      echo "  -p, --path <chemin>     Chemin spécifique à restaurer (Défaut: TOUT)"
      echo "  --list                  Affiche les snapshots disponibles pour l'host choisi"
      echo "  --help                  Affiche ce message (incroyable, non ?)"
      exit 0
    }

    while [[ "$#" -gt 0 ]]; do
      case $1 in
        -h|--host) TARGET_HOST="$2"; shift ;;
        -p|--path) TARGET_PATH="$2"; shift ;;
        --list)    MODE="LIST"; ;;
        -h|--help)    show_help ;;
        *) echo "Option inconnue: $1"; exit 1 ;;
      esac
      shift
    done

    # --- 3. CHARGEMENT ENVIRONNEMENT ---
    # On charge les secrets S3/B2/Minio
    if [ -f "${toString backupCfg.environmentFile}" ]; then
      set -a
      source "${toString backupCfg.environmentFile}"
      set +a
    fi
    export RESTIC_PASSWORD_FILE="${backupCfg.passwordFile}"
    export RESTIC_REPOSITORY_FILE="${backupCfg.repositoryFile}"

    # --- 4. EXÉCUTION ---

    # Petit helper pour voir ce qu'on a avant de taper
    if [ "$MODE" == "LIST" ]; then
      echo "🔍 Snapshots disponibles pour l'host '$TARGET_HOST':"
      ${pkgs.restic}/bin/restic snapshots --host "$TARGET_HOST"
      exit 0
    fi

    # Choix des dossiers à restaurer
    if [ -n "$TARGET_PATH" ]; then
      PATHS_TO_RESTORE="$TARGET_PATH"
      echo "🎯 Mode CIBLÉ : On ne restaure que '$TARGET_PATH'"
    else
      PATHS_TO_RESTORE="$NIX_PATHS"
      echo "📦 Mode TOTAL : On restaure tout ce qui est défini dans la config NixOS."
    fi

    echo " "
    echo "⚠️  ATTENTION ⚠️"
    echo "Tu vas écraser les données locales avec celles venant de :"
    echo "   Host Source : $TARGET_HOST"
    echo "   Dossiers    : $PATHS_TO_RESTORE"
    echo " "
    read -p "Écris 'GO' pour confirmer le carnage : " confirm
    if [ "$confirm" != "GO" ]; then echo "Annulé."; exit 1; fi

    for path in $PATHS_TO_RESTORE; do
      echo "---------------------------------------------------"
      echo "♻️  Restoring $path (Source: $TARGET_HOST)..."
      
      # La commande magique
      ${pkgs.restic}/bin/restic restore latest \
        --target / \
        --include "$path" \
        --host "$TARGET_HOST"
        
      if [ $? -eq 0 ]; then
        echo "✅ Succès pour $path"
      else
        echo "❌ Échec pour $path (Vérifie que ce chemin existe dans le backup de cet host !)"
      fi
    done

    echo "---------------------------------------------------"
    echo "Terminé. Vérifie tes fichiers."
  '';

in
{
  config = lib.mkIf enabled {
    environment.systemPackages = [
      restoreScript
    ];
  };
}
