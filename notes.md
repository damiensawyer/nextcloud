# Architecture & design notes

> Looking for how to **run** it? See [README.md](README.md). This file explains
> *why* the stack is built the way it is.

Three containers behind an nginx reverse proxy, all served on
**`http://cloud.test:8080`**:

- `http://cloud.test:8080`     → nginx → Nextcloud
- `http://collabora.test:8080` → nginx → Collabora

nginx solves the split-hostname problem: the browser, Nextcloud, and Collabora all
use the SAME domain names for each service, and every party resolves them to nginx,
which routes by `server_name`.

Default credentials: **`admin` / `admin`** (auto-created on first boot).

---

## Why NOT *.localhost (this bit us)

The domains must NOT be under `.localhost`. glibc hardcodes `*.localhost` → 127.0.0.1
inside `getaddrinfo()` and ignores both `/etc/hosts` and Docker's DNS. So inside a
container `collabora.localhost` loops back to the container *itself*, not to nginx:

- Nextcloud → `collabora.localhost/hosting/discovery` hit Nextcloud's own Apache and
  returned `400 Bad Request` (an HTML Nextcloud page). This was the original bug.
- Collabora → `cloud.localhost` (the WOPI callback) would have looped back the same way.

`.test` is a reserved TLD that is NOT special-cased, so:
- Docker's embedded DNS (127.0.0.11) resolves it inside containers via nginx network
  aliases (see `docker-compose.yaml` → nginx → `networks.default.aliases`).
- In the Podman pod, `--add-host` / `hostAliases` map it to `127.0.0.1`.
- The host resolves it via one hosts-file line (see README Step 1).

## Why nginx was needed

Without a reverse proxy there are three conflicting URL requirements:
1. Browser → Collabora: needs a hostname the browser can resolve.
2. Nextcloud → Collabora: needs a hostname that resolves inside the container network.
3. Collabora → Nextcloud WOPI callback: needs a hostname Collabora can reach.

nginx + a single `.test` domain per service (resolvable everywhere) satisfies all three.
The dev host also has UFW with a default DROP policy, which blocked container → host
traffic, ruling out the simpler `network_mode: host` approach for Collabora.

## Why port 8080 (the invariant that makes Collabora work)

Everything is published on **:8080**, not :80. Two reasons:

1. **Rootless Podman** can't bind privileged ports (< 1024) unless you lower
   `net.ipv4.ip_unprivileged_port_start`. Using :8080 avoids touching the host.
2. **One URL must work from two places.** The WOPI URL
   (`http://collabora.test:8080`) is used both by the browser *and* by Nextcloud
   server-side. So the port in that URL has to reach nginx in **both** contexts.

The rule we keep everywhere: **published host port == nginx listen port == the port
in every WOPI/overwrite URL == 8080.**

- **Docker Compose:** containers are separate, so nginx just listens on :8080
  (published `8080:8080`) and proxies to `nextcloud-frontend:80` and
  `collabora-backend:9980` by name. See `nginx.conf`.
- **Podman pod:** all containers share one network namespace, so two of them can't
  both use :8080. nginx takes :8080 and Nextcloud's Apache is moved to **:8081**
  (an idempotent `sed`, see `pod.sh` / `nextcloud-kube.yaml`); nginx proxies to
  `127.0.0.1:8081` and `127.0.0.1:9980`. See `nginx.pod.conf`.

If nginx listened on :80 internally while the browser used :8080, Nextcloud's
in-container call to `collabora.test:8080` would hit Apache (or nothing) instead of
nginx, and document editing would silently break.

---

## How the turnkey setup works (no wizard, no manual Collabora config)

The Nextcloud container configures itself on first boot via env vars (set in
`docker-compose.yaml`, `pod.sh`, and `nextcloud-kube.yaml`):

- `SQLITE_DATABASE=nextcloud` + `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD`
  → unattended install with an admin user, **no web wizard**.
  *(On Nextcloud 30+, `SQLITE_DATABASE` is required — without it the entrypoint
  falls through to the interactive installer.)*
- `NEXTCLOUD_TRUSTED_DOMAINS=cloud.test:8080 …` → no "untrusted domain" screen.
- `OVERWRITEHOST` / `OVERWRITEPROTOCOL` / `OVERWRITECLIURL` → Nextcloud generates
  correct `:8080` URLs (redirects, WOPI callbacks, etc).

Collabora Office (the `richdocuments` app) is installed and pointed at Collabora by
a small hook script, `hooks/before-starting/office.sh`, which the Nextcloud image
runs **as www-data on every boot** from `/docker-entrypoint-hooks.d/before-starting/`.
It is idempotent and always exits 0 (a non-zero exit would abort container startup).
It sets `wopi_url` / `public_wopi_url` to `http://collabora.test:8080` and clears the
WOPI allow-list (local dev = allow all). The Docker and Podman setups bind-mount this
file; the kube manifest ships the same script as a ConfigMap with `defaultMode: 0755`
(the executable bit matters — the entrypoint skips non-executable hooks).

> **First-boot note:** because the hook runs *before* Apache starts and installs
> `richdocuments` from the app store, the site returns `502` for ~30–60s on the very
> first boot. Later boots are instant (the app is already installed).

---

## Scripts

| Script | Runtime | What it does |
|--------|---------|--------------|
| `start.sh` | Docker | `docker compose up -d`. |
| `pod.sh` | Podman | Creates the pod + all three containers imperatively (`--fresh` wipes data). |
| `fix.sh` | Docker | **Break-glass.** Clears Nextcloud's sticky "App Store not available" cache. |
| `fix-pod.sh` | Podman | Same as `fix.sh`, via `podman exec`. |

### About `fix.sh` / `fix-pod.sh` — when (and whether) to run them

These are **not** part of normal startup. They only exist to fix one symptom:
the Apps page showing *"App Store not available"* / *"couldn't find any apps"*,
which also prevents the Office app from installing.

Root cause is DNS — the Nextcloud container can't reach `apps.nextcloud.com`.
Both the Compose and Podman definitions already give Nextcloud `8.8.8.8` /
`1.1.1.1`, so you normally won't hit this. The catch: the first time Nextcloud
fails, it caches a sticky `appstorenotavailable` flag and keeps showing the
error even after DNS is fine. The fix scripts clear that cache and force a fresh
catalog pull:

1. `occ config:app:delete core appstorenotavailable` — drop the sticky flag.
2. `occ config:app:delete core appstoreenabled` — reset the cached app-store state.
3. `occ app:update --all` — re-fetch the live catalog.

Run the one matching your runtime **only if** the Apps page misbehaves, then
restart the stack so the Office hook can finish.

---

## Manual Collabora config (reference)

The Office wiring is automatic, but if you ever need to do it by hand — via the UI
at `http://cloud.test:8080/settings/admin/richdocuments` ("Use your own server" →
`http://collabora.test:8080`), or via `occ`:

```
occ config:system:set trusted_domains 1 --value=cloud.test:8080
occ config:system:set overwritehost      --value=cloud.test:8080
occ config:system:set overwriteprotocol  --value=http
occ config:system:set overwrite.cli.url  --value=http://cloud.test:8080
occ config:app:set richdocuments wopi_url        --value=http://collabora.test:8080
occ config:app:set richdocuments public_wopi_url --value=http://collabora.test:8080
```
