#!/usr/bin/env bash
set -euo pipefail

if [ ! -f flake.nix ] || [ ! -d secrets ]; then
  echo "Error: run check-project from an initialized private deployment repository." >&2
  exit 1
fi

if rg -n '(sops\.|sopsFile|deployment\.keys|/run/secrets|builtins\.readFile|dnsCredentials[[:space:]]*=|accounts[[:space:]]*=|password(File)?[[:space:]]*=|grafanaSecret(File)?[[:space:]]*=|repository(File)?[[:space:]]*=|env(File)?[[:space:]]*=|config(Content|File)[[:space:]]*=)' config; then
  echo "Error: config/ must contain functional infra.* choices only." >&2
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
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILED=0
while IFS= read -r FILE; do
  PLAIN="$TMP/$(basename "$FILE").json"
  if ! SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops decrypt --output "$PLAIN" "$FILE"; then
    echo "Error: cannot decrypt $FILE." >&2
    exit 1
  fi
  if jq -e 'any(.. | strings; contains("CHANGEME"))' "$PLAIN" > /dev/null; then
    echo "Error: $FILE still contains CHANGEME." >&2
    FAILED=1
  fi
done < <(find secrets -type f -name '*.json' -print | sort)
[ "$FAILED" -eq 0 ] || exit 1

nix flake check --all-systems
colmena eval --impure -E '{ nodes, ... }: builtins.mapAttrs (_: node: node.config.system.build.toplevel.drvPath) nodes'
