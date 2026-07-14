#!/usr/bin/env bash
set -euo pipefail

actual=$(INFECT_SERVER_PARSE_ONLY=1 bash "$(dirname "$0")/infect.sh" \
    -p 2222 --post-port 2200 debian@example.test nixos-25.11)
expected="bootstrap=2222 post=2200 target=debian@example.test post_target=root@example.test channel=nixos-25.11"
[ "$actual" = "$expected" ] || {
    echo "unexpected parser output: $actual" >&2
    exit 1
}
