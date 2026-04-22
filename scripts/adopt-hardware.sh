#!/usr/bin/env bash
set -e

# Ce script récupère la configuration matérielle générée par nixos-infect
# et l'enregistre dans le dépôt git pour que Colmena puisse l'utiliser.

TOPOLOGY_FILE="./inventory/topology.nix"
HARDWARE_DIR="./inventory/hardware"

# Vérification jq
if ! command -v jq &> /dev/null;
then
    echo "❌ Erreur: 'jq' n'est pas installé."
    exit 1
fi

mkdir -p "$HARDWARE_DIR"

echo "🔮 Lecture de la topologie..."
JSON_DATA=$(nix-instantiate --eval --json --strict -E "import $TOPOLOGY_FILE" | jq .)

for HOSTNAME in $(echo "$JSON_DATA" | jq -r '.nodes | keys[]'); do
    PUBLIC_IP=$(echo "$JSON_DATA" | jq -r ".nodes[\"$HOSTNAME\"].publicIp")

    USER=$(echo "$JSON_DATA" | jq -r ".nodes[\"$HOSTNAME\"].user // \"root\"")
    SSH_KEY=$(echo "$JSON_DATA" | jq -r ".nodes[\"$HOSTNAME\"].sshKey // \"~/.ssh/id_ed25519\"")

    DEST_DIR="$HARDWARE_DIR/$HOSTNAME"
    DEST_FILE="$DEST_DIR/hardware.nix"
    
    mkdir -p "$DEST_DIR"

    echo "📡 Connexion à $HOSTNAME ($PUBLIC_IP)..."
    
    # On essaie de récupérer hardware-configuration.nix
    if scp -i "$SSH_KEY" "$USER@$PUBLIC_IP:/etc/nixos/hardware-configuration.nix" "$DEST_FILE" > /dev/null 2>&1; then
        echo "✅ Hardware config récupérée pour $HOSTNAME"
    else
        echo "⚠️  Impossible de récupérer la config pour $HOSTNAME (Peut-être pas encore infecté ?)"
        
        # Si le fichier n'existe pas localement, on crée un placeholder pour ne pas casser Colmena
        if [ ! -f "$DEST_FILE" ]; then
            echo "📝 Création d'un placeholder vide pour $DEST_FILE"
            echo "{ modulesPath, ... }: { imports = [ (modulesPath + \"/profiles/qemu-guest.nix\") ]; }" > "$DEST_FILE"
        fi
    fi
done
