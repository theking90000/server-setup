#!/usr/bin/env bash
set -e

# --- CONFIGURATION DU PIPELINE D'ASSETS ---
TOPOLOGY_FILE="./inventory/topology.nix"
SECRETS_DIR="./.secrets"

# Vérification des prérequis (Compliance check)
if ! command -v jq &> /dev/null; then
    echo "❌ [BLOCKER] 'jq' manquant. Impossible de parser le JSON."
    exit 1
fi

# 1. Ingestion de la topologie (Data Mining)
echo "🔮 Audit de la topologie Nix en cours..."
JSON_DATA=$(nix-instantiate --eval --json --strict -E "import $TOPOLOGY_FILE" | jq .)

# Création du répertoire racine (si inexistant)
mkdir -p "$SECRETS_DIR"

# 2. Itération sur les nœuds (Batch Processing)
for HOSTNAME in $(echo "$JSON_DATA" | jq -r '.nodes | keys[]'); do
    
    HOST_DIR="$SECRETS_DIR/$HOSTNAME"
    OUTPUT_KEY="$HOST_DIR/key.pub"
    mkdir -p "$HOST_DIR"

    echo -n "🔍 Analyse de la configuration pour '$HOSTNAME' : "

    # Récupération du chemin de la clé privée via la config SSH résolue
    # On prend la première occurrence de 'identityfile' renvoyée par ssh -G
    RAW_KEY_PATH=$(ssh -G "$HOSTNAME" | awk '/^identityfile/ {print $2; exit}')

    # Expansion du tilde (~) si présent, car bash ne l'expand pas dans une variable string
    KEY_PATH="${RAW_KEY_PATH/#\~/$HOME}"

    # Vérification de l'existence de la clé privée
    if [ ! -f "$KEY_PATH" ]; then
        echo "⚠️  [WARNING] Clé introuvable ($KEY_PATH). Skip."
        continue
    fi

    # Extraction de la clé publique depuis la clé privée
    # Utilisation de ssh-keygen -y pour garantir l'exactitude mathématique de la paire
    if ssh-keygen -y -f "$KEY_PATH" > "$OUTPUT_KEY" 2>/dev/null; then
        echo "✅ Clé exportée vers $OUTPUT_KEY"
    else
        echo "❌ [FAILURE] Impossible d'extraire la clé publique (Passphrase requise ?)."
    fi

done

echo "🚀 Workflow 'export-ssh-key' terminé. Synergie atteinte."