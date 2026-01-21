#!/usr/bin/env bash
set -e

# Chemins
TOPOLOGY_FILE="./inventory/topology.nix"
SECRETS_DIR="./.secrets"
OUTPUT_NIX="$SECRETS_DIR/mesh.nix"

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

# Initialisation du fichier de sortie
mkdir -p "$SECRETS_DIR"
echo "{" > "$OUTPUT_NIX"
echo "  mesh = {" >> "$OUTPUT_NIX"

# 2. Boucle sur les nœuds
for HOSTNAME in $(echo "$JSON_DATA" | jq -r '.nodes | keys[]'); do
    
    # Récupération des infos du host via jq
    VPN_IP=$(echo "$JSON_DATA" | jq -r ".nodes[\"$HOSTNAME\"].vpnIp")
    PUBLIC_IP=$(echo "$JSON_DATA" | jq -r ".nodes[\"$HOSTNAME\"].publicIp")
    
    HOST_DIR="$SECRETS_DIR/$HOSTNAME"
    mkdir -p "$HOST_DIR"
    
    PRIV_KEY="$HOST_DIR/wireguard.private"
    PUB_KEY="$HOST_DIR/wireguard.public"

    # Génération des clés si absentes
    if [ ! -f "$PRIV_KEY" ]; then
        echo "🔑 Génération des clés pour $HOSTNAME..."
        # wg genkey outputs a newline, which can cause issues in some contexts. Trimming it:
        wg genkey | tr -d '\n' | tee "$PRIV_KEY" | wg pubkey | tr -d '\n' > "$PUB_KEY"
    fi

    PUB_CONTENT=$(cat "$PUB_KEY")

    # Ajout au fichier Nix public
    echo "    \"$HOSTNAME\" = {" >> "$OUTPUT_NIX"
    echo "      publicKey = \"$PUB_CONTENT\";" >> "$OUTPUT_NIX"
    echo "      vpnIp = \"$VPN_IP\";" >> "$OUTPUT_NIX"
    echo "      publicIp = \"$PUBLIC_IP\";" >> "$OUTPUT_NIX"
    echo "    };" >> "$OUTPUT_NIX"
done

# Fermeture du fichier Nix
echo "  };
}" >> "$OUTPUT_NIX"

echo "✅ Configuration Mesh mise à jour : $OUTPUT_NIX"
