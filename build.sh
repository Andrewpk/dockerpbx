#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build the FreePBX arm64 image on the Pi.
#
# This exists because the build takes ~22 minutes and MUST NOT run inside a
# Portainer stack deploy (it blows past Portainer's timeout -> DeadlineExceeded).
# So docker-compose.yml has no build: block; you build here, deploy there.
#
# Reads build args from .env (same file Compose uses). Run over SSH, let it
# finish, THEN deploy/redeploy the stack in Portainer -- it'll use this image.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "No .env found next to build.sh. Copy .env.example and fill it in."; exit 1; }
set -a; . ./.env; set +a

: "${INSTALLER_REF:?set INSTALLER_REF in .env (pin to a commit SHA)}"
: "${FREEPBX_DB_PASS:?set FREEPBX_DB_PASS in .env}"

docker build --progress=plain \
  --build-arg INSTALLER_REF="${INSTALLER_REF}" \
  --build-arg FREEPBX_DB_PASS="${FREEPBX_DB_PASS}" \
  --build-arg APACHE_PORT="${APACHE_PORT:-8080}" \
  --build-arg PBX_HOSTNAME="${PBX_HOSTNAME:-pbx.home.arpa}" \
  --build-arg TZ="${TZ:-Atlantic/Reykjavik}" \
  -t freepbx-arm64:local \
  . 2>&1 | tee /tmp/pbx-build.log

echo
echo "Build done. Image tagged freepbx-arm64:local. Now deploy the stack in Portainer."
