#!/bin/bash
# ==============================================================================
# SCRIPT NAME: pod.sh
# DESCRIPTION: Builds the Nextcloud + Collabora + nginx stack as a Podman pod,
#              imperatively (the `podman pod create` + `podman run` equivalent
#              of nextcloud-kube.yaml / docker-compose.yaml).
#
# Because a pod shares one network namespace:
#   * --add-host / --dns are set ONCE on the pod (containers inherit them).
#   * nginx keeps :80; Nextcloud's Apache is moved to :8080 to avoid the clash.
#   * containers talk over 127.0.0.1 (see nginx.pod.conf).
#
# Re-running this script recreates the pod from scratch. The named volume
# `nextcloud_data` is preserved so Nextcloud's data survives.
# ==============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
POD=nextcloud

# --- Fresh pod every run, but keep the data volume -----------------------------
if podman pod exists "$POD"; then
    echo "🔄 Pod '$POD' already exists — removing it..."
    podman pod rm -f "$POD"
fi

if ! podman volume exists nextcloud_data; then
    echo "📦 Creating volume 'nextcloud_data'..."
    podman volume create nextcloud_data
fi

# --- The pod: publishes :80 and injects the .test -> 127.0.0.1 host entries ----
echo "🚀 Creating pod '$POD'..."
podman pod create --name "$POD" \
    -p 80:80 \
    --add-host cloud.test:127.0.0.1 \
    --add-host collabora.test:127.0.0.1 \
    --dns 8.8.8.8 \
    --dns 1.1.1.1

# --- Collabora backend (9980) --------------------------------------------------
echo "📝 Starting Collabora..."
podman run -d --pod "$POD" --name collabora-backend \
    --restart always \
    --cap-add SYS_ADMIN \
    --cap-add MKNOD \
    -e "aliasgroup1=http://cloud.test" \
    -e "extra_params=--o:ssl.enable=false --o:ssl.termination=false" \
    docker.io/collabora/code:latest

# --- Nextcloud frontend (Apache moved to 8080) ---------------------------------
# --entrypoint /bin/sh so our sed runs first, then we exec the stock entrypoint.
# The sed is idempotent, so surviving-container restarts stay correct.
echo "☁️  Starting Nextcloud..."
podman run -d --pod "$POD" --name nextcloud-frontend \
    --restart always \
    -v nextcloud_data:/var/www/html \
    --entrypoint /bin/sh \
    docker.io/library/nextcloud:latest \
    -c 'sed -i "s/^Listen 80$/Listen 8080/" /etc/apache2/ports.conf; sed -i "s/:80>/:8080>/" /etc/apache2/sites-enabled/000-default.conf; exec /entrypoint.sh apache2-foreground'

# --- nginx reverse proxy (owns :80) -------------------------------------------
echo "🌐 Starting nginx..."
podman run -d --pod "$POD" --name nginx-proxy \
    --restart always \
    -v "$DIR/nginx.pod.conf:/etc/nginx/conf.d/default.conf:ro" \
    docker.io/library/nginx:alpine

echo
echo "✅ Pod '$POD' is up."
echo "   One-time host setup (if not done):"
echo "     echo '127.0.0.1 cloud.test collabora.test' | sudo tee -a /etc/hosts"
echo "   Then open http://cloud.test  (see notes.md for post-startup steps)."
