#!/usr/bin/env bash
set -euo pipefail

DEFAULT_NIX_CHANNEL="nixos-26.05"
INFECT_REV="40f62a680bb0e8f2f607d79abfaaecd99d59401c"
INFECT_SHA256="4354bd68773b41da65c0e815202c43c8549713b3ed3ff6381c71fbc0b0a840ab"
SSH_IDENTITY=""
SSH_PORT=22
POST_PORT=22

usage() {
    echo "Usage: infect-server [-i identity_file] [-p bootstrap_port] [--post-port final_port] <user@ip> [nix_channel]"
    echo "Example: infect-server -i ~/.ssh/id_ed25519 -p 22 --post-port 2222 debian@1.2.3.4"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -i)
            [ $# -ge 2 ] || usage
            SSH_IDENTITY="$2"
            shift 2
            ;;
        -p)
            [ $# -ge 2 ] || usage
            SSH_PORT="$2"
            shift 2
            ;;
        --post-port)
            [ $# -ge 2 ] || usage
            POST_PORT="$2"
            shift 2
            ;;
        -h|--help) usage ;;
        --) shift; break ;;
        -*) usage ;;
        *) break ;;
    esac
done

[ $# -ge 1 ] || usage
TARGET="$1"
NIX_CHANNEL="${2:-$DEFAULT_NIX_CHANNEL}"
TARGET_HOST="${TARGET#*@}"
POST_TARGET="root@${TARGET_HOST}"

for port in "$SSH_PORT" "$POST_PORT"; do
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
        echo "Error: invalid SSH port '$port'." >&2
        exit 1
    }
done
[[ "$NIX_CHANNEL" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "Error: invalid NixOS channel '$NIX_CHANNEL'." >&2
    exit 1
}

if [ "${INFECT_SERVER_PARSE_ONLY:-0}" = 1 ]; then
    printf 'bootstrap=%s post=%s target=%s post_target=%s channel=%s\n' \
        "$SSH_PORT" "$POST_PORT" "$TARGET" "$POST_TARGET" "$NIX_CHANNEL"
    exit 0
fi

SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SCP_OPTS=(-P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
POST_SSH_OPTS=(-p "$POST_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
if [ -n "$SSH_IDENTITY" ]; then
    SSH_IDENTITY="${SSH_IDENTITY/#\~/$HOME}"
    [ -f "$SSH_IDENTITY" ] || { echo "Error: identity file '$SSH_IDENTITY' not found." >&2; exit 1; }
    SSH_OPTS+=(-i "$SSH_IDENTITY")
    SCP_OPTS+=(-i "$SSH_IDENTITY")
    POST_SSH_OPTS+=(-i "$SSH_IDENTITY")
fi

KEY_SOURCE=""
if [ -n "$SSH_IDENTITY" ] && [ -f "${SSH_IDENTITY}.pub" ]; then
    KEY_SOURCE="${SSH_IDENTITY}.pub"
elif [ -f "$HOME/.ssh/authorized_keys" ]; then
    KEY_SOURCE="$HOME/.ssh/authorized_keys"
elif [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    KEY_SOURCE="$HOME/.ssh/id_ed25519.pub"
else
    echo "Error: no public SSH key found; refusing to risk locking root out." >&2
    exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
INFECT_SCRIPT="$WORK_DIR/nixos-infect"
SSH_MODULE="$WORK_DIR/server-setup-ssh.nix"
AUTHORIZED_KEYS="$WORK_DIR/server-setup-authorized-keys"
cp "$KEY_SOURCE" "$AUTHORIZED_KEYS"

curl -fsSL \
    "https://raw.githubusercontent.com/elitak/nixos-infect/$INFECT_REV/nixos-infect" \
    -o "$INFECT_SCRIPT"
echo "$INFECT_SHA256  $INFECT_SCRIPT" | sha256sum --check --status || {
    echo "Error: nixos-infect checksum mismatch." >&2
    exit 1
}

cat > "$SSH_MODULE" <<EOF
{ ... }:
{
  services.openssh.ports = [ $POST_PORT ];
  networking.firewall.allowedTCPPorts = [ $POST_PORT ];
}
EOF

echo "Infecting $TARGET (bootstrap port $SSH_PORT, final port $POST_PORT)..."
OS_NAME=$(ssh "${SSH_OPTS[@]}" "$TARGET" "grep PRETTY_NAME /etc/os-release" 2>/dev/null || true)
if [[ "$OS_NAME" == *NixOS* ]]; then
    echo "Remote is already NixOS; nothing to do."
    exit 0
fi

scp "${SCP_OPTS[@]}" "$AUTHORIZED_KEYS" "$INFECT_SCRIPT" "$SSH_MODULE" "$TARGET:/tmp/"
REMOTE_COMMAND="if [ \"\$(id -u)\" -eq 0 ]; then SUDO=; elif command -v sudo >/dev/null 2>&1; then SUDO=sudo; else echo 'Error: bootstrap user is not root and sudo is unavailable.' >&2; exit 1; fi; \$SUDO mkdir -p /root/.ssh /etc/nixos && \$SUDO install -m 600 /tmp/server-setup-authorized-keys /root/.ssh/authorized_keys && \$SUDO install -m 644 /tmp/server-setup-ssh.nix /etc/nixos/server-setup-ssh.nix && \$SUDO env NIX_CHANNEL=$NIX_CHANNEL NIXOS_IMPORT=./server-setup-ssh.nix bash /tmp/nixos-infect"
# The fixed remote command is intentionally assembled locally.
# shellcheck disable=SC2029
ssh "${SSH_OPTS[@]}" "$TARGET" "$REMOTE_COMMAND" || echo "SSH disconnected while nixos-infect rebooted the host."

echo "Waiting up to 2 minutes for the host to go down..."
down=false
for _ in $(seq 1 60); do
    if ! ssh "${POST_SSH_OPTS[@]}" -q -o ConnectTimeout=2 "$POST_TARGET" exit 2>/dev/null; then
        down=true
        break
    fi
    sleep 2
done
[ "$down" = true ] || echo "Host was not observed down; continuing with final-port verification."

echo "Waiting up to 10 minutes for SSH on final port $POST_PORT..."
for _ in $(seq 1 120); do
    if ssh "${POST_SSH_OPTS[@]}" -q -o ConnectTimeout=3 "$POST_TARGET" exit 2>/dev/null; then
        ssh "${POST_SSH_OPTS[@]}" "$POST_TARGET" "grep PRETTY_NAME /etc/os-release"
        echo "Infection complete. Final SSH endpoint: $POST_TARGET port $POST_PORT"
        exit 0
    fi
    sleep 5
done

echo "Error: SSH did not return on final port $POST_PORT within 10 minutes." >&2
exit 1
