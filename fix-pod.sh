#!/bin/bash
# ==============================================================================
# SCRIPT NAME: fix-pod.sh
# DESCRIPTION: Podman version of fix.sh. BREAK-GLASS ONLY — run this only if the
#              Nextcloud Apps page shows "App Store not available" / "couldn't
#              find any apps".
#
# Root cause is DNS (the container can't reach apps.nextcloud.com). The pod is
# already given 8.8.8.8/1.1.1.1, so you normally won't need this. But Nextcloud
# caches a sticky "appstorenotavailable" flag the first time it fails, and keeps
# showing the error even after DNS is fine — this clears that cache and forces a
# fresh catalog pull.
# ==============================================================================
set -euo pipefail

echo "=== Nextcloud App Store Fixer (podman) ==="

# The container is 'nextcloud-frontend' (pod.sh) or 'nextcloud-nextcloud' (kube).
CONTAINER_NAME=""
for c in nextcloud-frontend nextcloud-nextcloud; do
    if [ "$(podman inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ]; then
        CONTAINER_NAME="$c"; break
    fi
done

if [ -z "$CONTAINER_NAME" ]; then
    echo "❌ Error: Nextcloud container is not running."
    echo "Please start the pod first (./pod.sh  or  podman play kube nextcloud-kube.yaml)."
    exit 1
fi
echo "Using container '${CONTAINER_NAME}'."

echo "🔄 Step 1: Clearing Nextcloud app store offline flags..."
podman exec -u www-data "${CONTAINER_NAME}" php occ config:app:delete core appstorenotavailable

echo "🔄 Step 2: Clearing app store connection cache..."
podman exec -u www-data "${CONTAINER_NAME}" php occ config:app:delete core appstoreenabled

echo "⚙️  Step 3: Forcing an internal app data update..."
podman exec -u www-data "${CONTAINER_NAME}" php occ app:update --all

echo "✨ Done! Refresh your browser at http://cloud.test:8080 and check the Apps tab."
