# Architecture

Three containers behind an nginx reverse proxy:

- `http://cloud.test`     → nginx → nextcloud-frontend:80
- `http://collabora.test` → nginx → collabora-backend:9980

nginx solves the split-hostname problem: the browser, Nextcloud, and Collabora all
use the SAME domain names for each service, and every party resolves them to nginx,
which routes by `server_name`.

## Why NOT *.localhost (this bit us)

The domains must NOT be under `.localhost`. glibc hardcodes `*.localhost` → 127.0.0.1
inside `getaddrinfo()` and ignores both `/etc/hosts` and Docker's DNS. So inside a
container `collabora.localhost` loops back to the container *itself*, not to nginx:

- Nextcloud → `collabora.localhost/hosting/discovery` hit Nextcloud's own Apache and
  returned `400 Bad Request` (an HTML Nextcloud page). This was the original bug.
- Collabora → `cloud.localhost` (the WOPI callback) would have looped back the same way.

`.test` is a reserved TLD that is NOT special-cased, so:

- Docker's embedded DNS (127.0.0.11) resolves it inside containers via nginx network
  aliases (see docker-compose.yaml → nginx → networks.default.aliases).
- The host resolves it via one `/etc/hosts` line (see setup below).

## Why nginx was needed

Without a reverse proxy there are three conflicting URL requirements:

1. Browser → Collabora: needs a hostname the browser can resolve.
2. Nextcloud → Collabora: needs a hostname that resolves inside Docker.
3. Collabora → Nextcloud WOPI callback: needs a hostname Collabora can reach in Docker.

nginx + a single `.test` domain per service (resolvable everywhere) satisfies all three.
The host also has UFW with a default DROP policy, which blocked Docker container → host
traffic, ruling out the simpler network_mode:host approach for Collabora.

Credentials: damien / password

# One-time Host Setup

`.test` is not auto-resolved by browsers, so add it to the host hosts file ONCE:

```
echo '127.0.0.1 cloud.test collabora.test' | sudo tee -a /etc/hosts
```

# Post-Startup Setup

After `docker-compose up -d`, do the following once in the Nextcloud UI.

## Step 1 — Fix the app store (if it says "couldn't find any apps")

Run `./fix.sh`, then refresh the browser.

## Step 2 — Install Nextcloud Office app

Go to: `http://cloud.test/index.php/settings/apps` → search **"Nextcloud Office"** →
click **Enable**.

## Step 3 — Configure it to use Collabora

Go to: `http://cloud.test/settings/admin/richdocuments`

Select **"Use your own server"** and enter:

```
http://collabora.test
```

Click **Save**. It should show a green "Collabora Online is reachable" confirmation.

(Equivalent via CLI — already applied by the setup:)

```
occ config:system:set trusted_domains 0 --value=cloud.test
occ config:system:set overwrite.cli.url  --value=http://cloud.test
occ config:system:set overwritehost      --value=cloud.test
occ config:system:set overwriteprotocol  --value=http
occ config:app:set richdocuments wopi_url       --value=http://collabora.test
occ config:app:set richdocuments wopi_allowlist --value=172.16.0.0/12
```

## Step 4 — Open an ODT or DOCX file

Upload any `.odt` or `.docx` file and click it. It should open in the embedded editor.

> Access Nextcloud at <http://cloud.test> (not localhost:8080)
