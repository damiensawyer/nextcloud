#!/bin/bash
# ==============================================================================
# SCRIPT NAME: pod.sh
# DESCRIPTION: Builds the Nextcloud + Collabora + nginx stack as a Podman pod,
#              imperatively (the `podman pod create` + `podman run` equivalent
#              of nextcloud-kube.yaml / docker-compose.yaml).
#
# The whole stack is served on http://cloud.test:8080 (see README.md).
#
# Because a pod shares one network namespace:
#   * --add-host / --dns are set ONCE on the pod (containers inherit them).
#   * nginx listens on :8080 (published to the host); Nextcloud's Apache is moved
#     to :8081 to avoid the clash. Everything — browser, host publish, nginx, and
#     the in-pod WOPI URLs — uses the SAME :8080, so a single URL works from the
#     browser AND from inside the pod (this is the invariant that keeps Collabora
#     discovery working). :8080 (>1024) also lets rootless podman bind it without
#     touching net.ipv4.ip_unprivileged_port_start.
#   * containers talk over 127.0.0.1 (see nginx.pod.conf).
#
# Re-running this script recreates the pod from scratch. The named volume
# `nextcloud_data` is preserved so Nextcloud's data survives (pass --fresh to
# wipe it and reinstall from a clean slate).
# ==============================================================================
set -euo pipefail

# --- Config (override via env, e.g. HOST_PORT=9000 ./pod.sh) -------------------
POD=nextcloud
HOST_PORT="${HOST_PORT:-8080}"
BASE_HOST="${BASE_HOST:-cloud.test}"
OFFICE_HOST="${OFFICE_HOST:-collabora.test}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"
BASE_URL="http://${BASE_HOST}:${HOST_PORT}"
OFFICE_URL="http://${OFFICE_HOST}:${HOST_PORT}"

DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Fresh pod every run, but keep the data volume (unless --fresh) ------------
if podman pod exists "$POD"; then
    echo "🔄 Pod '$POD' already exists — removing it..."
    podman pod rm -f "$POD" >/dev/null
fi

if [[ "${1:-}" == "--fresh" ]] && podman volume exists nextcloud_data; then
    echo "🧹 --fresh: removing the nextcloud_data volume for a clean install..."
    podman volume rm nextcloud_data >/dev/null
fi

if ! podman volume exists nextcloud_data; then
    echo "📦 Creating volume 'nextcloud_data'..."
    podman volume create nextcloud_data >/dev/null
fi

# --- The pod: publishes :HOST_PORT and injects .test -> 127.0.0.1 host entries -
echo "🚀 Creating pod '$POD' (http://${BASE_HOST}:${HOST_PORT})..."
podman pod create --name "$POD" \
    -p "${HOST_PORT}:8080" \
    --add-host "${BASE_HOST}:127.0.0.1" \
    --add-host "${OFFICE_HOST}:127.0.0.1" \
    --dns 8.8.8.8 \
    --dns 1.1.1.1 >/dev/null

# --- Collabora backend (9980) --------------------------------------------------
echo "📝 Starting Collabora..."
podman run -d --pod "$POD" --name collabora-backend \
    --restart always \
    --cap-add SYS_ADMIN \
    --cap-add MKNOD \
    -e "aliasgroup1=${BASE_URL}" \
    -e "extra_params=--o:ssl.enable=false --o:ssl.termination=false --o:server_name=${OFFICE_HOST}:${HOST_PORT}" \
    docker.io/collabora/code:latest >/dev/null

# --- Nextcloud frontend (Apache moved to 8081) ---------------------------------
# --entrypoint /bin/sh so our sed runs first, then we exec the stock entrypoint.
# The sed is idempotent, so surviving-container restarts stay correct. The
# NEXTCLOUD_* env vars make the stock entrypoint auto-install (SQLite) and create
# the admin on first boot, and register the :8080 host so there is no wizard and
# no "untrusted domain" redirect.
echo "☁️  Starting Nextcloud..."
podman run -d --pod "$POD" --name nextcloud-frontend \
    --restart always \
    -v nextcloud_data:/var/www/html \
    -e "SQLITE_DATABASE=nextcloud" \
    -e "NEXTCLOUD_ADMIN_USER=${ADMIN_USER}" \
    -e "NEXTCLOUD_ADMIN_PASSWORD=${ADMIN_PASS}" \
    -e "NEXTCLOUD_TRUSTED_DOMAINS=${BASE_HOST}:${HOST_PORT} ${BASE_HOST}" \
    -e "OVERWRITEHOST=${BASE_HOST}:${HOST_PORT}" \
    -e "OVERWRITEPROTOCOL=http" \
    -e "OVERWRITECLIURL=${BASE_URL}" \
    -e "OFFICE_URL=${OFFICE_URL}" \
    -v "$DIR/hooks/before-starting/office.sh:/docker-entrypoint-hooks.d/before-starting/office.sh:ro" \
    --entrypoint /bin/sh \
    docker.io/library/nextcloud:latest \
    -c 'sed -i "s/^Listen 80$/Listen 8081/" /etc/apache2/ports.conf; sed -i "s/:80>/:8081>/" /etc/apache2/sites-enabled/000-default.conf; exec /entrypoint.sh apache2-foreground' >/dev/null

# --- nginx reverse proxy (owns :8080) -----------------------------------------
echo "🌐 Starting nginx..."
podman run -d --pod "$POD" --name nginx-proxy \
    --restart always \
    -v "$DIR/nginx.pod.conf:/etc/nginx/conf.d/default.conf:ro" \
    docker.io/library/nginx:alpine >/dev/null

# --- Wait for install, then wire up Collabora Office ---------------------------
# The nextcloud container auto-installs (SQLite) on first boot from the env above,
# and the mounted before-starting hook wires up Office. We run that same hook here
# synchronously so its result is visible now; it is idempotent and non-fatal (if
# the app store is unreachable the base stack still works — see README).
echo -n "⏳ Waiting for Nextcloud to finish installing"
installed=""
for _ in $(seq 1 60); do
    if podman exec -u www-data nextcloud-frontend php occ status 2>/dev/null | grep -q "installed: true"; then
        installed=1; break
    fi
    echo -n "."; sleep 3
done
echo

if [[ "$installed" == "1" ]]; then
    echo "🧩 Configuring Collabora Office..."
    podman exec -u www-data -e "OFFICE_URL=${OFFICE_URL}" nextcloud-frontend \
        sh /docker-entrypoint-hooks.d/before-starting/office.sh 2>&1 | sed 's/^office-hook: /   ✓ /'
else
    echo "   ⚠ Nextcloud did not report 'installed' in time — check 'podman logs nextcloud-frontend'."
fi

echo
echo "✅ Pod '$POD' is up.  →  ${BASE_URL}"
echo "   Login: ${ADMIN_USER} / ${ADMIN_PASS}"
echo "   If the browser can't resolve ${BASE_HOST}, add the hosts entry (see README.md):"
echo "     echo '127.0.0.1 ${BASE_HOST} ${OFFICE_HOST}' | sudo tee -a /etc/hosts"
