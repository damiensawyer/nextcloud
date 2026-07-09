#!/bin/bash
# Start the Docker Compose stack (Nextcloud + Collabora + nginx) on
# http://cloud.test:8080. See README.md for the one-time hosts-file setup.
#
# Uses Compose v2 (`docker compose`, built into modern Docker). If you are on old
# standalone Compose, swap it for `docker-compose`.
set -euo pipefail
cd "$(dirname "$0")"
docker compose up -d
echo
echo "✅ Stack starting →  http://cloud.test:8080   (login: admin / admin)"
echo "   First boot pulls images and auto-installs; give it a minute."
