#!/usr/bin/env bash
set -e

# Chemins
TOPOLOGY_FILE="./inventory/nodes.nix"
WG_DIR="./inventory/wireguard"

# Vérification des dépendances
if ! command -v jq &> /dev/null;
then
    echo "❌ Erreur: 'jq' n'est pas installé"
    exit 1
fi

if ! command -v wg &> /dev/null;
then
    echo "❌ Erreur: 'wireguard-tools' n'est pas installé"
    exit 1
fi

# 1. Extraction de la configuration depuis Nix
echo "🔮 Lecture de la topologie Nix..."

JSON_DATA=$(nix-instantiate --eval --json --strict -E "import $TOPOLOGY_FILE" | jq .)

# 2. Boucle sur les nœuds
for HOSTNAME in $(echo "$JSON_DATA" | jq -r '.nodes | keys[]'); do
    
    HOST_DIR="$WG_DIR/$HOSTNAME"
    mkdir -p "$HOST_DIR"
    
    PRIV_KEY="$HOST_DIR/private.key"
    PUB_KEY="$HOST_DIR/public.key"

    # Génération des clés si absentes
    if [ ! -f "$PRIV_KEY" ]; then
        echo "🔑 Génération des clés pour $HOSTNAME..."
        # wg genkey outputs a newline, which can cause issues in some contexts. Trimming it:
        wg genkey | tr -d '\n' | tee "$PRIV_KEY" | wg pubkey | tr -d '\n' > "$PUB_KEY"
    fi

echo "✅ Clés générées pour $HOSTNAME : $PRIV_KEY et $PUB_KEY"
done
