#!/usr/bin/env bash
# Create the first Rakazo account from the running API container.
# Run as root from the deployment directory:
#   sudo bash /srv/containers/rakazo/bootstrap-owner.sh
set -euo pipefail

cd /srv/containers/rakazo

# Password input is hidden. Keep prompting instead of passing an empty value
# to the CLI, which only reports "OWNER_PASSWORD is required".
while true; do
  read -r -p "Account email: " OWNER_EMAIL || exit 1
  [[ -n "$OWNER_EMAIL" ]] && break
  echo "Email cannot be empty." >&2
done

while true; do
  read -r -s -p "Account password (16+ chars): " OWNER_PASSWORD || exit 1
  echo
  [[ -n "$OWNER_PASSWORD" ]] && break
  echo "Password cannot be empty; type it, then press Enter." >&2
done

# Compose's `exec -e VAR` reads the value from its own environment. The
# variables must be exported; shell-local variables are not passed through.
export OWNER_EMAIL OWNER_PASSWORD

docker compose --env-file .env -f docker-compose.images.yml \
  exec -e OWNER_EMAIL -e OWNER_PASSWORD api \
  node dist/cli/bootstrap-owner.js

unset OWNER_EMAIL OWNER_PASSWORD
