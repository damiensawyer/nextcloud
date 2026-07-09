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


# Running with Podman (alternative to Docker Compose)

The same stack is also provided for Podman, where all three containers run in a
single **pod** (one shared network namespace = they talk over `127.0.0.1`).

Two ways to start it, pick one:

- **Declarative** — `podman play kube nextcloud-kube.yaml`
  (tear down with `podman play kube --down nextcloud-kube.yaml`).
- **Imperative** — `./pod.sh`, which builds the pod with `podman pod create` +
  `podman run`. Re-running it recreates the pod from scratch while preserving
  the `nextcloud_data` volume.

Both are equivalent to `docker-compose.yaml`. Because a pod can't have two
containers on `:80`, the Podman version keeps nginx on `:80` and moves
Nextcloud's Apache to `:8080` (an idempotent `sed`, see `pod.sh` /
`nextcloud-kube.yaml`). nginx then proxies to `127.0.0.1:8080` and
`127.0.0.1:9980` — this is why the Podman setup uses `nginx.pod.conf` instead of
`nginx.conf`. The Docker "network aliases" trick is replaced by `/etc/hosts`
entries (`hostAliases` / `--add-host`) mapping `cloud.test` and `collabora.test`
to `127.0.0.1`.

The one-time host setup above (the `/etc/hosts` line) still applies.

## Scripts

| Script | Runtime | What it does |
|--------|---------|--------------|
| `start.sh` | Docker | `docker-compose up -d`. |
| `pod.sh` | Podman | Creates the pod and all three containers imperatively. |
| `fix.sh` | Docker | **Break-glass.** Clears Nextcloud's sticky "App Store not available" cache. |
| `fix-pod.sh` | Podman | Same as `fix.sh`, via `podman exec`. |

### About `fix.sh` / `fix-pod.sh` — when (and whether) to run them

These are **not** part of normal startup. They only exist to fix one symptom:
the Apps page showing *"App Store not available"* / *"couldn't find any apps"*.

Root cause is DNS — the Nextcloud container can't reach `apps.nextcloud.com`.
Both the Compose and Podman definitions already give Nextcloud `8.8.8.8` /
`1.1.1.1`, so you normally won't hit this. The catch: the first time Nextcloud
fails, it caches a sticky `appstorenotavailable` flag and keeps showing the
error even after DNS is fine. The fix scripts clear that cache and force a fresh
catalog pull:

1. `occ config:app:delete core appstorenotavailable` — drop the sticky flag.
2. `occ config:app:delete core appstoreenabled` — reset the cached app-store state.
3. `occ app:update --all` — re-fetch the live catalog.

Run the one matching your runtime (`./fix.sh` for Docker, `./fix-pod.sh` for
Podman) **only if** the Apps page misbehaves, then refresh the browser.


# Post-Startup Setup

After the stack is up (`docker-compose up -d`, `./pod.sh`, or
`podman play kube …`), do the following once in the Nextcloud UI.

## Step 1 — Fix the app store (if it says "couldn't find any apps")

Run `./fix.sh` (Docker) or `./fix-pod.sh` (Podman), then refresh the browser.
See "About `fix.sh` / `fix-pod.sh`" above — you usually won't need this.

## Step 2 — Install Nextcloud Office app

Go to: `http://cloud.test/index.php/settings/apps` → search **"Nextcloud Office"** →
click **Enable**.

## Step 3 — Configure it to use Collabora

Go to: `http://cloud.test/settings/admin/richdocuments`

Select **"Use your own server"** and enter:

```
http://collabora.test
```

Set the **WOPI allow list** to:

```
172.16.0.0/12
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

> Access Nextcloud at http://cloud.test (not localhost:8080)
