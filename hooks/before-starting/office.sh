#!/bin/sh
# ==============================================================================
# Nextcloud "before-starting" hook — auto-wires Collabora Office.
#
# The stock Nextcloud entrypoint runs every executable *.sh in
# /docker-entrypoint-hooks.d/before-starting/ as www-data on every boot. This
# script installs the "Nextcloud Office" (richdocuments) app and points it at the
# Collabora backend, so the stack is usable with zero clicks. It is idempotent
# and MUST always exit 0 — a non-zero exit aborts container startup.
#
# OFFICE_URL is the browser+in-pod URL of Collabora (default http://collabora.test:8080).
# ==============================================================================
OFFICE_URL="${OFFICE_URL:-http://collabora.test:8080}"
occ="php /var/www/html/occ"

# Only proceed once Nextcloud itself is installed.
$occ status 2>/dev/null | grep -q "installed: true" || exit 0

if ! $occ app:list 2>/dev/null | grep -q richdocuments; then
    echo "office-hook: installing richdocuments (Nextcloud Office)..."
    $occ app:install richdocuments 2>/dev/null \
        || echo "office-hook: could not install richdocuments (app store unreachable?) — will retry next boot."
fi

if $occ app:list 2>/dev/null | grep -q richdocuments; then
    $occ config:app:set richdocuments wopi_url        --value="$OFFICE_URL" 2>/dev/null || true
    $occ config:app:set richdocuments public_wopi_url --value="$OFFICE_URL" 2>/dev/null || true
    # Local dev: allow Collabora from any source IP (no WOPI IP allow-list).
    $occ config:app:delete richdocuments wopi_allowlist 2>/dev/null || true
    echo "office-hook: richdocuments pointed at ${OFFICE_URL}"
fi

exit 0
