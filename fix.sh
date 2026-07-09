
#!/bin/bash

# ==============================================================================
# SCRIPT NAME: fix.sh
# DESCRIPTION: Resolves Nextcloud App Store connectivity and caching issues.
# HOW IT WORKS:
#   1. Verifies that the 'nextcloud-frontend' container is active.
#   2. Deletes the 'appstorenotavailable' flag from the Nextcloud database.
#   3. Clears stale network connectivity and cache states.
#   4. Triggers a manual, server-side pull of the live Nextcloud App catalog.
# ==============================================================================

# Define the target Nextcloud container name
CONTAINER_NAME="nextcloud-frontend"

echo "=== Nextcloud App Store Fixer ==="

# Check if the container is currently active
if [ ! "$(docker ps -q -f name=${CONTAINER_NAME})" ]; then
    echo "❌ Error: Container '${CONTAINER_NAME}' is not running."
    echo "Please run 'docker-compose up -d' first."
    exit 1
fi

echo "🔄 Step 1: Clearing Nextcloud app store offline flags..."
docker exec -it -u www-data ${CONTAINER_NAME} php occ config:app:delete core appstorenotavailable

echo "🔄 Step 2: Clearing app store connection cache..."
docker exec -it -u www-data ${CONTAINER_NAME} php occ config:app:delete core appstoreenabled

echo "⚙️ Step 3: Forcing an internal app data update..."
docker exec -it -u www-data ${CONTAINER_NAME} php occ app:update --all

echo "✨ Done! Refresh your browser at http://cloud.test and check the Apps tab."
