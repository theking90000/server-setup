#!/usr/bin/env bash
set -e

# Chemins
KEYS_DIR="./inventory/keys"

if [ ! -f "$KEYS_DIR/syncer.key" ]; then
    echo "🔑 Génération de la clé SSH pour le cert-syncer..."
    mkdir -p "$KEYS_DIR"
    ssh-keygen -t ed25519 -f "$KEYS_DIR/syncer.key" -N "" -C "cert-syncer-key"
    echo "✅ Clé générée et stockée dans $KEYS_DIR/syncer.key"
fi

echo "🔑 Extraction de la clé publique..."
ssh-keygen -y -f "$KEYS_DIR/syncer.key" > "$KEYS_DIR/syncer.key.pub"
echo "✅ Clé publique extraite vers $KEYS_DIR/syncer.key.pub"

