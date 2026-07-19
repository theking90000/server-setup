#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: update-nixos-release [--check] [YY.05|YY.11]" >&2
    exit 2
}

CHECK_ONLY=false
if [ "${1:-}" = "--check" ]; then
    CHECK_ONLY=true
    shift
fi
[ $# -le 1 ] || usage

[ -f flake.nix ] && [ -f scripts/infect.sh ] || {
    echo "Error: run this command from the public server-setup repository." >&2
    exit 1
}

CURRENT=$(sed -nE 's#.*github:NixOS/nixpkgs/nixos-([0-9]{2}\.(05|11))".*#\1#p' flake.nix)
[ -n "$CURRENT" ] || {
    echo "Error: unable to read the current NixOS release from flake.nix." >&2
    exit 1
}

TARGET=${1:-}
if [ -z "$TARGET" ]; then
    YEAR=$(date +%y)
    MONTH=$((10#$(date +%m)))
    if [ "$MONTH" -ge 12 ]; then
        TARGET="$YEAR.11"
    elif [ "$MONTH" -ge 6 ]; then
        TARGET="$YEAR.05"
    else
        TARGET="$(printf '%02d' "$((10#$YEAR - 1))").11"
    fi
fi

[[ "$TARGET" =~ ^[0-9]{2}\.(05|11)$ ]] || usage
curl -fsIL --retry 2 "https://channels.nixos.org/nixos-$TARGET" >/dev/null || {
    echo "Error: the official nixos-$TARGET channel is not available." >&2
    exit 1
}

NEWEST=$(printf '%s\n%s\n' "$CURRENT" "$TARGET" | sort -V | tail -n 1)
[ "$NEWEST" = "$TARGET" ] || {
    echo "Error: refusing to downgrade from $CURRENT to $TARGET." >&2
    exit 1
}

if [ "$CURRENT" = "$TARGET" ]; then
    echo "NixOS is already on release $CURRENT."
else
    echo "NixOS $CURRENT is outdated; target release is $TARGET."
fi

[ "$CHECK_ONLY" = false ] || exit 0

if [ "$CURRENT" != "$TARGET" ]; then
    sed -i -E \
        -e "s#nixos-[0-9]{2}\.(05|11)#nixos-$TARGET#g" \
        -e "s#nixpkgs-[0-9]{2}\.(05|11)-darwin#nixpkgs-$TARGET-darwin#g" \
        flake.nix
    sed -i -E "s#nixos-[0-9]{2}\.(05|11)#nixos-$TARGET#g" \
        scripts/infect.sh scripts/test-infect.sh
    sed -i -E "s#system\.stateVersion = \"[0-9]{2}\.(05|11)\";#system.stateVersion = \"$TARGET\";#g" \
        checks.nix template/flake.nix
fi

nix flake update nixpkgs nixpkgs-darwin
nix flake check --all-systems --no-build

echo "Public release updated and checked. Publish it, then update each private repository with its infra input."
