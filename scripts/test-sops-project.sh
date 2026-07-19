#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MOCKS="$TMP/mocks"
mkdir -p "$MOCKS"

make_mock() {
  local name=$1
  shift
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf '%s\n' "$@"
  } > "$MOCKS/$name"
  chmod +x "$MOCKS/$name"
}

make_mock nix-instantiate 'printf "%s\n" "$NODES_JSON"'
make_mock age-keygen '
if [ "${1:-}" = "-o" ]; then printf "AGE-SECRET-KEY-test\n" > "$2"; else echo age1admin; fi'
make_mock ssh 'printf "%s\n" "$*"'
make_mock ssh-to-age '
input=$(cat)
case "$input" in *192.0.2.2*) echo age1host2 ;; *) echo age1host1 ;; esac'
make_mock sops '
case "$1" in
  updatekeys)
    [ "${FAIL_UPDATE:-0}" = 0 ] || exit 42
    file=${@: -1}
    printf "# updated\n" >> "$file"
    ;;
  encrypt)
    output=
    source=${@: -1}
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--output" ]; then output=$2; shift 2; else shift; fi
    done
    cp "$source" "$output"
    ;;
  decrypt)
    shift
    if [ "${1:-}" = "--output" ]; then cp "$3" "$2"; else cat "$1"; fi
    ;;
esac'

for command in generate-mesh adopt-hardware export-ssh-key update-sops-keys colmena nix; do
  make_mock "$command" 'exit 0'
done

export PATH="$MOCKS:$PATH"
export SOPS_AGE_KEY_FILE="$TMP/admin-age-key"
export SOPS_LOG="$TMP/sops.log"

ONE_NODE='{"nodes":{"vps1":{"publicIp":"192.0.2.1","sshKey":"/tmp/key","sshPort":22,"tags":[]}}}'
TWO_NODES='{"nodes":{"vps1":{"publicIp":"192.0.2.1","sshKey":"/tmp/key","sshPort":22,"tags":[]},"vps2":{"publicIp":"192.0.2.2","sshKey":"/tmp/key","sshPort":22,"tags":[]}}}'

UPDATE_REPO="$TMP/update-repo"
mkdir -p "$UPDATE_REPO/inventory" "$UPDATE_REPO/secrets"
touch "$UPDATE_REPO/inventory/nodes.nix"
(
  cd "$UPDATE_REPO"
  NODES_JSON="$ONE_NODE" bash "$ROOT/scripts/update-sops-keys.sh"
  cp .sops.yaml "$TMP/one-node.yaml"
  printf 'ciphertext=keep\n' > secrets/app.json
  NODES_JSON="$ONE_NODE" bash "$ROOT/scripts/update-sops-keys.sh"
  cmp .sops.yaml "$TMP/one-node.yaml"
  grep -q 'ciphertext=keep' secrets/app.json

  NODES_JSON="$TWO_NODES" bash "$ROOT/scripts/update-sops-keys.sh"
  grep -q 'host_vps2' .sops.yaml
  grep -q 'ciphertext=keep' secrets/app.json

  NODES_JSON="$ONE_NODE" bash "$ROOT/scripts/update-sops-keys.sh"
  ! grep -q 'host_vps2' .sops.yaml

  cp .sops.yaml "$TMP/before-failure.yaml"
  cp secrets/app.json "$TMP/before-failure.json"
  if NODES_JSON="$TWO_NODES" FAIL_UPDATE=1 bash "$ROOT/scripts/update-sops-keys.sh"; then
    echo "update-sops-keys should fail when re-encryption fails" >&2
    exit 1
  fi
  cmp .sops.yaml "$TMP/before-failure.yaml"
  cmp secrets/app.json "$TMP/before-failure.json"
)

INIT_REPO="$TMP/init-repo"
mkdir -p "$INIT_REPO/inventory/wireguard/vps1" "$INIT_REPO/config"
touch "$INIT_REPO/inventory/nodes.nix" "$INIT_REPO/flake.nix"
printf 'wireguard-private\n' > "$INIT_REPO/inventory/wireguard/vps1/private.key"

BACKUP_NODE='{"nodes":{"vps1":{"publicIp":"192.0.2.1","sshKey":"/tmp/key","sshPort":22,"tags":["backup","applications/jellyfin","applications/rust-storage-streamer"]}}}'
(
  cd "$INIT_REPO"
  NODES_JSON="$BACKUP_NODE" bash "$ROOT/scripts/init-project.sh"
  test -f secrets/wireguard/vps1.json
  test -f secrets/restic.json
  test -f secrets/jellyfin.json
  test -f secrets/rust-storage-streamer.json
  jq -e '.jellarr_api_key | length == 64' secrets/jellyfin.json > /dev/null
  # sans web-server ni kanidm : aucun secret ACME
  test ! -f secrets/acme.json
  cp secrets/restic.json "$TMP/restic-before.json"
  cp secrets/jellyfin.json "$TMP/jellyfin-before.json"
  cp secrets/rust-storage-streamer.json "$TMP/rust-storage-streamer-before.json"
  NODES_JSON="$BACKUP_NODE" bash "$ROOT/scripts/init-project.sh"
  cmp secrets/restic.json "$TMP/restic-before.json"
  cmp secrets/jellyfin.json "$TMP/jellyfin-before.json"
  cmp secrets/rust-storage-streamer.json "$TMP/rust-storage-streamer-before.json"

  if bash "$ROOT/scripts/check-project.sh"; then
    echo "check-project should reject CHANGEME" >&2
    exit 1
  fi
  for secret in secrets/*.json; do
    sed 's/CHANGEME/configured/g' "$secret" > "$secret.tmp"
    mv "$secret.tmp" "$secret"
  done
  bash "$ROOT/scripts/check-project.sh"
)

SYNAPSE_REPO="$TMP/synapse-repo"
mkdir -p "$SYNAPSE_REPO/inventory/wireguard/vps1" "$SYNAPSE_REPO/config"
touch "$SYNAPSE_REPO/inventory/nodes.nix" "$SYNAPSE_REPO/flake.nix"
printf 'wireguard-private\n' > "$SYNAPSE_REPO/inventory/wireguard/vps1/private.key"

SYNAPSE_NODE='{"nodes":{"vps1":{"publicIp":"192.0.2.1","sshKey":"/tmp/key","sshPort":22,"tags":["applications/synapse","kanidm"]}}}'
(
  cd "$SYNAPSE_REPO"
  NODES_JSON="$SYNAPSE_NODE" bash "$ROOT/scripts/init-project.sh"
  jq -e '.registration_shared_secret | length == 64' secrets/synapse.json > /dev/null
  jq -e '.oidc_client_secret | length == 64' secrets/synapse.json > /dev/null
  jq -e '.idm_admin_password | length == 64' secrets/kanidm.json > /dev/null
  # kanidm consomme un certificat : secret ACME par émetteur, sans syncer
  jq -e '.issuers.primary.dnsCredentials | contains("CHANGEME")' secrets/acme.json > /dev/null
  test ! -f secrets/acme-syncer.json
)

echo "SOPS project script tests passed."
