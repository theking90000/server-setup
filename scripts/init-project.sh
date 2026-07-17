#!/usr/bin/env bash
set -euo pipefail
umask 077

if [ ! -f inventory/nodes.nix ] || [ ! -f flake.nix ]; then
  echo "Error: run init-project from a private deployment repository." >&2
  exit 1
fi

if rg -n 'CHANGEME' inventory/nodes.nix; then
  echo "Error: replace the topology CHANGEME values first." >&2
  exit 1
fi

generate-mesh
adopt-hardware
export-ssh-key
generate-key
update-sops-keys

case "$(uname -s)" in
  Darwin)
    DEFAULT_AGE_KEY="$HOME/Library/Application Support/sops/age/keys.txt"
    ;;
  *)
    DEFAULT_AGE_KEY="${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"
    ;;
esac
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$DEFAULT_AGE_KEY}"
NODES=$(nix-instantiate --eval --json --strict -E 'import ./inventory/nodes.nix')
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

has_tag() {
  jq -e --arg tag "$1" '[.nodes[].tags[]] | index($tag) != null' <<< "$NODES" > /dev/null
}

encrypt_new() {
  local source=$1
  local destination=$2
  if [ -f "$destination" ]; then
    return
  fi
  mkdir -p "$(dirname "$destination")"
  SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops encrypt \
    --filename-override "$destination" --output "$destination" "$source"
  echo "Created $destination"
}

random_file() {
  openssl rand -hex 32 > "$1"
}

while IFS= read -r HOSTNAME; do
  jq -n --rawfile privateKey "inventory/wireguard/$HOSTNAME/private.key" \
    '{privateKey: ($privateKey | rtrimstr("\n"))}' > "$TMP/wireguard-$HOSTNAME.json"
  encrypt_new "$TMP/wireguard-$HOSTNAME.json" "secrets/wireguard/$HOSTNAME.json"
done < <(jq -r '.nodes | keys[]' <<< "$NODES")

if has_tag "acme-issuer"; then
  jq -n '{dnsCredentials: "OVH_ENDPOINT=ovh-eu\nOVH_APPLICATION_KEY=CHANGEME\nOVH_APPLICATION_SECRET=CHANGEME\nOVH_CONSUMER_KEY=CHANGEME"}' > "$TMP/acme.json"
  encrypt_new "$TMP/acme.json" secrets/acme.json

  if [ "$(jq '.nodes | length' <<< "$NODES")" -gt 1 ]; then
    jq -n --rawfile privateKey inventory/keys/syncer.key \
      '{privateKey: $privateKey}' > "$TMP/acme-syncer.json"
    encrypt_new "$TMP/acme-syncer.json" secrets/acme-syncer.json
  fi
fi

if has_tag "backup"; then
  random_file "$TMP/restic-password"
  jq -n --rawfile password "$TMP/restic-password" \
    '{repository: "CHANGEME", password: ($password | rtrimstr("\n")), env: "CHANGEME"}' \
    > "$TMP/restic.json"
  encrypt_new "$TMP/restic.json" secrets/restic.json
fi

if has_tag "grafana"; then
  random_file "$TMP/grafana-password"
  random_file "$TMP/grafana-secret"
  random_file "$TMP/grafana-oidc"
  jq -n \
    --rawfile password "$TMP/grafana-password" \
    --rawfile grafanaSecret "$TMP/grafana-secret" \
    --rawfile oidcSecret "$TMP/grafana-oidc" \
    '{password: ($password | rtrimstr("\n")), grafana_secret: ($grafanaSecret | rtrimstr("\n")), oidc_client_secret: ($oidcSecret | rtrimstr("\n"))}' \
    > "$TMP/grafana.json"
  encrypt_new "$TMP/grafana.json" secrets/grafana.json
fi

if has_tag "applications/gitea" && has_tag "kanidm"; then
  random_file "$TMP/gitea-oidc"
  jq -n --rawfile secret "$TMP/gitea-oidc" \
    '{oidc_client_secret: ($secret | rtrimstr("\n"))}' > "$TMP/gitea.json"
  encrypt_new "$TMP/gitea.json" secrets/gitea.json
fi

if has_tag "applications/synapse"; then
  random_file "$TMP/synapse-registration"
  if has_tag "kanidm"; then
    random_file "$TMP/synapse-oidc"
    jq -n \
      --rawfile registrationSecret "$TMP/synapse-registration" \
      --rawfile oidcSecret "$TMP/synapse-oidc" \
      '{registration_shared_secret: ($registrationSecret | rtrimstr("\n")), oidc_client_secret: ($oidcSecret | rtrimstr("\n"))}' \
      > "$TMP/synapse.json"
  else
    jq -n --rawfile registrationSecret "$TMP/synapse-registration" \
      '{registration_shared_secret: ($registrationSecret | rtrimstr("\n"))}' \
      > "$TMP/synapse.json"
  fi
  encrypt_new "$TMP/synapse.json" secrets/synapse.json
fi

if has_tag "kanidm" && {
  has_tag "grafana" || has_tag "applications/gitea" || has_tag "applications/synapse"
}; then
  random_file "$TMP/kanidm-password"
  jq -n --rawfile password "$TMP/kanidm-password" \
    '{idm_admin_password: ($password | rtrimstr("\n"))}' > "$TMP/kanidm.json"
  encrypt_new "$TMP/kanidm.json" secrets/kanidm.json
fi

if has_tag "applications/docker-registry"; then
  jq -n '{accounts: "CHANGEME"}' > "$TMP/docker-registry.json"
  encrypt_new "$TMP/docker-registry.json" secrets/docker-registry.json
fi

if has_tag "applications/rust-storage-streamer"; then
  jq -n '{webhooks: "CHANGEME"}' > "$TMP/rust-storage-streamer.json"
  encrypt_new "$TMP/rust-storage-streamer.json" secrets/rust-storage-streamer.json
fi

if [ -f config/rclone-sync/rclone-sync.nix ]; then
  mapfile -t RCLONE_MOUNTS < <(
    rg -o '^\s*"[^"]+"\s*=\s*\{' config/rclone-sync/rclone-sync.nix \
      | sed -E 's/^\s*"([^"]+)".*/\1/'
  )
  if [ "${#RCLONE_MOUNTS[@]}" -gt 0 ]; then
    printf '%s\n' "${RCLONE_MOUNTS[@]}" \
      | jq -Rn '[inputs | select(length > 0) | {key: ., value: "CHANGEME"}] | from_entries' \
      > "$TMP/rclone-sync.json"
    encrypt_new "$TMP/rclone-sync.json" secrets/rclone-sync.json
  fi
fi

PENDING=0
while IFS= read -r FILE; do
  while IFS= read -r FIELD; do
    [ -n "$FIELD" ] || continue
    printf 'Pending: sops %s  (%s)\n' "$FILE" "$FIELD"
    PENDING=1
  done < <(
    SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops decrypt "$FILE" \
      | jq -r 'paths(strings) as $p | select(getpath($p) | contains("CHANGEME")) | $p | map(tostring) | join(".")'
  )
done < <(find secrets -type f -name '*.json' -print | sort)

if [ "$PENDING" -eq 0 ]; then
  echo "Project initialized; no external secret is missing."
else
  echo "Project initialized; fill the encrypted fields listed above."
fi
