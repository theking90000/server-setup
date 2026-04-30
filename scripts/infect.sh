#!/usr/bin/env bash
set -e

# Configuration
DEFAULT_NIX_CHANNEL="nixos-25.11"
KEYS_FILE="$HOME/.ssh/authorized_keys"
DEFAULT_PUB_KEY="$HOME/.ssh/id_ed25519.pub"
SSH_IDENTITY=""
SSH_OPTS=()

usage() {
    echo "Usage: $0 [-i identity_file] <user@ip> [nix_channel]"
    echo "Example: $0 -i ~/.ssh/my_custom_key debian@1.2.3.4"
    exit 1
}

# Parse options
while getopts "i:" opt; do
  case $opt in
    i)
      SSH_IDENTITY="$OPTARG"
      if [ ! -f "$SSH_IDENTITY" ]; then
        echo "❌ Error: Identity file '$SSH_IDENTITY' not found."
        exit 1
      fi
      SSH_OPTS=("-i" "$SSH_IDENTITY")
      ;;
    *)
      usage
      ;;
  esac
done
shift $((OPTIND-1))

# Usage check
if [ -z "$1" ]; then
    usage
fi

TARGET="$1"
NIX_CHANNEL="${2:-$DEFAULT_NIX_CHANNEL}"

echo "🚀 Infection target: $TARGET"
echo "📦 NixOS Channel: $NIX_CHANNEL"

# 1. Check current OS
echo "🔍 Checking remote OS..."
OS_NAME=$(ssh "${SSH_OPTS[@]}" -o StrictHostKeyChecking=no "$TARGET" "cat /etc/os-release" 2>/dev/null | grep PRETTY_NAME || true)

if [[ "$OS_NAME" == *"NixOS"* ]]; then
    echo "✅ Remote is already NixOS. Aborting infection."
    exit 0
fi

echo "❌ Remote is NOT NixOS. Preparing to infect..."

# 2. Prepare keys
# Ansible script copies ~/.ssh/authorized_keys. We try that, or fallback to public key.
KEY_SOURCE=""

if [ -n "$SSH_IDENTITY" ]; then
    PUB_KEY="${SSH_IDENTITY}.pub"
    if [ -f "$PUB_KEY" ]; then
        echo "🔑 Using public key from identity ($PUB_KEY)"
        KEY_SOURCE="$PUB_KEY"
    else
        echo "⚠️  Public key for identity not found at $PUB_KEY"
    fi
fi

if [ -z "$KEY_SOURCE" ]; then
    if [ -f "$KEYS_FILE" ]; then
        echo "🔑 Using local authorized_keys ($KEYS_FILE)"
        KEY_SOURCE="$KEYS_FILE"
    elif [ -f "$DEFAULT_PUB_KEY" ]; then
        echo "🔑 authorized_keys not found. Using default public key ($DEFAULT_PUB_KEY)"
        KEY_SOURCE="$DEFAULT_PUB_KEY"
    else
        echo "⚠️  No SSH keys found to propagate. Root might be inaccessible after infection!"
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
fi

echo "💉 Injecting NixOS..."

# Combine key setup and infection
ssh "${SSH_OPTS[@]}" -o StrictHostKeyChecking=no "$TARGET" "
    # Prepare
    if ! command -v curl >/dev/null; then
        if command -v apt-get >/dev/null; then
            sudo apt-get update && sudo apt-get install -y curl
        elif command -v yum >/dev/null; then
            sudo yum install -y curl
        fi
    fi
    sudo umount /tmp 2>/dev/null || true
    
    # Keys
    echo '🔑 Setting up /root/.ssh/authorized_keys...'
    sudo mkdir -p /root/.ssh
    sudo chmod 700 /root/.ssh
    # Read from stdin (the piped keys) and write to authorized_keys
    sudo tee /root/.ssh/authorized_keys > /dev/null
    sudo chmod 600 /root/.ssh/authorized_keys

    # Infect
    echo '🚀 Launching nixos-infect...'
    curl https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect | NIX_CHANNEL=$NIX_CHANNEL sudo bash
" < "$KEY_SOURCE"

echo "⏳ Waiting for SSH to go down..."
# Simple wait loop
count=0
while ssh "${SSH_OPTS[@]}" -q -o ConnectTimeout=2 "$TARGET" exit 2>/dev/null; do
    printf "."
    sleep 2
    count=$((count+1))
    if [ $count -gt 30 ]; then
        echo " (Warning: Host seems stubborn, maybe it's installing...)"
        break
    fi
done
echo ""
echo "📉 Host is down (or network reset). Waiting for it to come back up..."

# Wait for up
while ! ssh "${SSH_OPTS[@]}" -q -o ConnectTimeout=2 "$TARGET" exit 2>/dev/null; do
    printf "."
    sleep 5
done
echo ""
echo "✅ Host is BACK!"

echo "🔍 Verifying NixOS..."
ssh "${SSH_OPTS[@]}" -o StrictHostKeyChecking=no "$TARGET" "grep PRETTY_NAME /etc/os-release"

echo "🎉 Infection complete."
echo "--------------------------------------------------------"
echo "Next steps:"
echo "1. Verify you can SSH as root: ssh root@<ip>"
echo "2. Add the host to 'inventory/nodes.nix' if not already present."
echo "3. Run deployment/mesh generation scripts."
