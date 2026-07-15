#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -gt 1 ]; then
  echo "Usage: deploy-project [host]" >&2
  exit 1
fi

init-project
check-project

if [ "$#" -eq 1 ]; then
  colmena apply --on "$1"
else
  colmena apply
fi
