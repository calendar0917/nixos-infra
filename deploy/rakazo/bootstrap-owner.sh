#!/usr/bin/env bash
# Create the first Rakazo account from the running API container.
# Run as root from the deployment directory:
#   sudo bash /srv/containers/rakazo/bootstrap-owner.sh
set -euo pipefail

cd /srv/containers/rakazo

read -r -p "Account email: " OWNER_EMAIL
read -r -s -p "Account password (16+ chars): " OWNER_PASSWORD
echo

# Compose's `exec -e VAR` reads the value from its own environment. The
# variables must be exported; shell-local variables are not passed through.
export OWNER_EMAIL OWNER_PASSWORD

docker compose --env-file .env -f docker-compose.images.yml \
  exec -e OWNER_EMAIL -e OWNER_PASSWORD api \
  node dist/cli/bootstrap-owner.js

unset OWNER_EMAIL OWNER_PASSWORD
