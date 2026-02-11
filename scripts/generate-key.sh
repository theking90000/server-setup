#!/usr/bin/env bash
set -e

# Chemins
SECRETS_DIR="./.secrets"

if [ ! -f "$SECRETS_DIR/syncer.key" ]; then
    echo "🔑 Génération de la clé SSH pour le cert-syncer..."
    mkdir -p "$SECRETS_DIR"
    ssh-keygen -t ed25519 -f "$SECRETS_DIR/syncer.key" -N "" -C "cert-syncer-key"
    echo "✅ Clé générée et stockée dans $SECRETS_DIR/syncer.key"
fi

echo "🔑 Extraction de la clé publique..."
ssh-keygen -y -f "$SECRETS_DIR/syncer.key" > "$SECRETS_DIR/syncer.key.pub"
echo "✅ Clé publique extraite vers $SECRETS_DIR/syncer.key.pub"

