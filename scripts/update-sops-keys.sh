#!/usr/bin/env bash
set -euo pipefail
umask 077

if [ ! -f inventory/nodes.nix ]; then
  echo "Error: run update-sops-keys from a private deployment repository." >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin)
    DEFAULT_AGE_KEY="$HOME/Library/Application Support/sops/age/keys.txt"
    ;;
  *)
    DEFAULT_AGE_KEY="${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"
    ;;
esac

AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$DEFAULT_AGE_KEY}"
if [ ! -f "$AGE_KEY_FILE" ]; then
  mkdir -p "$(dirname "$AGE_KEY_FILE")"
  age-keygen -o "$AGE_KEY_FILE"
fi
chmod 0600 "$AGE_KEY_FILE"
ADMIN_RECIPIENT=$(age-keygen -y "$AGE_KEY_FILE")

NODES=$(nix-instantiate --eval --json --strict -E 'import ./inventory/nodes.nix')
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/project/secrets"

CONFIG="$WORK/project/.sops.yaml"
{
  echo "keys:"
  printf '  - &admin %s\n' "$ADMIN_RECIPIENT"
} > "$CONFIG"

while IFS= read -r HOSTNAME; do
  PUBLIC_IP=$(jq -r --arg host "$HOSTNAME" '.nodes[$host].publicIp' <<< "$NODES")
  SSH_PORT=$(jq -r --arg host "$HOSTNAME" '.nodes[$host].sshPort // 22' <<< "$NODES")
  SSH_KEY=$(jq -r --arg host "$HOSTNAME" '.nodes[$host].sshKey // "~/.ssh/id_ed25519"' <<< "$NODES")
  SSH_KEY="${SSH_KEY/#\~/$HOME}"

  echo "Reading the SSH host key for $HOSTNAME..."
  HOST_RECIPIENT=$(
    ssh -o BatchMode=yes -i "$SSH_KEY" -p "$SSH_PORT" "root@$PUBLIC_IP" \
      'cat /etc/ssh/ssh_host_ed25519_key.pub' | ssh-to-age
  )
  ANCHOR=$(printf '%s' "$HOSTNAME" | tr -c 'A-Za-z0-9_' '_')
  printf '  - &host_%s %s\n' "$ANCHOR" "$HOST_RECIPIENT" >> "$CONFIG"
done < <(jq -r '.nodes | keys[]' <<< "$NODES")

{
  echo ""
  echo "creation_rules:"
  echo "  - path_regex: secrets/.*\\.json$"
  echo "    key_groups:"
  echo "      - age:"
  echo "          - *admin"
  while IFS= read -r HOSTNAME; do
    ANCHOR=$(printf '%s' "$HOSTNAME" | tr -c 'A-Za-z0-9_' '_')
    printf '          - *host_%s\n' "$ANCHOR"
  done < <(jq -r '.nodes | keys[]' <<< "$NODES")
} >> "$CONFIG"

if [ -f .sops.yaml ] && cmp -s .sops.yaml "$CONFIG"; then
  echo "SOPS recipients are already current."
  exit 0
fi

if [ -d secrets ]; then
  cp -R secrets/. "$WORK/project/secrets/"
fi

if find "$WORK/project/secrets" -type f -name '*.json' -print -quit | grep -q .; then
  echo "Re-encrypting SOPS files in a staging directory..."
  (
    cd "$WORK/project"
    while IFS= read -r FILE; do
      SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops updatekeys --yes "$FILE"
    done < <(find secrets -type f -name '*.json' -print | sort)
  )
fi

mkdir -p secrets
cp "$CONFIG" .sops.yaml
if [ -d "$WORK/project/secrets" ]; then
  cp -R "$WORK/project/secrets/." secrets/
fi
echo "SOPS recipients updated."
