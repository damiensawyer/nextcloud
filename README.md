# Nextcloud + Collabora Office — local dev stack

A one-command [Nextcloud](https://nextcloud.com/) instance with
[Collabora Online](https://www.collaboraonline.com/) (document editing) behind an
nginx reverse proxy. Runs on **Docker** or **Podman**, on **Linux, macOS, and
Windows**.

Everything is served at **http://cloud.test:8080** and logs in with **`admin` / `admin`**.

- ✅ No setup wizard — the admin user and database are created automatically.
- ✅ Collabora Office is installed and wired up automatically.
- ✅ One URL (`http://cloud.test:8080`) works from your browser *and* between the
  containers, so document editing "just works".

---

## Prerequisites

Pick **one** container runtime:

| Runtime | Linux | macOS | Windows |
|---------|-------|-------|---------|
| **Docker** (Docker Desktop / Engine) — easiest cross-platform | ✔ | ✔ | ✔ |
| **Podman** (rootless) — native on Linux | ✔ | ✔ (podman machine) | ✔ (podman machine) |

> **Why port 8080 and not 80?** Rootless Podman can't bind privileged ports
> (< 1024) without a host tweak, so the whole stack standardises on `8080` for a
> consistent, hassle-free experience on every OS.

---

## Step 1 — Add the hostnames (one time)

The stack uses the domains `cloud.test` and `collabora.test`, which must resolve
to your machine. Add them to your **hosts file**:

**Linux / macOS**
```bash
echo '127.0.0.1 cloud.test collabora.test' | sudo tee -a /etc/hosts
```

**Windows** (PowerShell **as Administrator**)
```powershell
Add-Content -Path $env:WINDIR\System32\drivers\etc\hosts -Value "127.0.0.1 cloud.test collabora.test"
```
*(Or open `C:\Windows\System32\drivers\etc\hosts` in Notepad run as Administrator
and add the line `127.0.0.1 cloud.test collabora.test`.)*

> Don't use a `*.localhost` domain — glibc hard-codes those to `127.0.0.1` and
> ignores DNS, which breaks container-to-container calls. `.test` is a reserved
> TLD that stays under your control. (See [notes.md](notes.md) for the full story.)

---

## Step 2 — Start it

Choose the command for your runtime (run from this directory):

**Docker** (any OS)
```bash
docker compose up -d          # or: ./start.sh
```

**Podman — imperative script** (Linux)
```bash
./pod.sh                      # add --fresh to wipe data and reinstall
```

**Podman — declarative manifest** (Linux)
```bash
podman play kube nextcloud-kube.yaml
# stop with: podman play kube --down nextcloud-kube.yaml
```

The **first** start pulls images and runs the unattended install, so give it a
minute. During that first boot the site briefly returns `502` while the Office
app downloads — this is normal and clears on its own.

---

## Step 3 — Use it

Open **http://cloud.test:8080** and log in:

```
Username: admin
Password: admin
```

To try document editing, click **+ New → New document** (or upload a `.docx` /
`.odt`) — it opens in the embedded Collabora editor. Nothing else to configure.

---

## Managing the stack

| Action | Docker | Podman (`pod.sh`) | Podman (kube) |
|--------|--------|-------------------|---------------|
| Start | `docker compose up -d` | `./pod.sh` | `podman play kube nextcloud-kube.yaml` |
| Stop | `docker compose down` | `podman pod stop nextcloud` | `podman play kube --down nextcloud-kube.yaml` |
| Logs | `docker compose logs -f nextcloud` | `podman logs -f nextcloud-frontend` | `podman logs -f nextcloud-nextcloud` |
| **Reset (wipe data)** | `docker compose down -v` | `./pod.sh --fresh` | `--down`, then `podman volume rm nextcloud-data` |

Data lives in a named volume (`nextcloud_data` / the `nextcloud-data` PVC) and
survives normal restarts. Use the **Reset** row to start over from scratch — do
this if you change the port or hostname, since those are baked in at install time.

---

## Customising

`pod.sh` reads a few environment variables (defaults shown):

```bash
HOST_PORT=8080  BASE_HOST=cloud.test  OFFICE_HOST=collabora.test \
ADMIN_USER=admin  ADMIN_PASS=admin  ./pod.sh --fresh
```

For Docker / kube, edit the `environment:` / `env:` blocks in
`docker-compose.yaml` / `nextcloud-kube.yaml` (and the matching hostnames in
`nginx.conf` / the manifest's ConfigMap).

---

## Troubleshooting

**"Access through untrusted domain" or it redirects to a dead URL**
The data volume was created with a different port/hostname. Reset it (see the
table above) so the install picks up the current settings.

**Login page never loads / `502 Bad Gateway` right after starting**
First-boot only: Nextcloud is still installing and the Office app is downloading.
Wait ~1 minute. Check progress with the *Logs* command above.

**Document editor won't open — "browser has been unable to connect to the Collabora server"**
Collabora must advertise its public host *and port*. It's set via
`--o:server_name=collabora.test:8080` on the Collabora container (already in all
three configs). If you changed the port/host, update it there too, then run
`occ richdocuments:activate-config` and hard-refresh the browser tab (Ctrl+Shift+R).
Note the admin "Collabora is reachable" check can be green even when this is wrong,
because that check is server-side — see [notes.md](notes.md).

**Apps page says "App Store not available" / Office didn't install**
The container couldn't reach `apps.nextcloud.com` on first boot (DNS/offline).
It retries on every restart, so just restart the stack once you're online — or
run the break-glass script: `./fix.sh` (Docker) / `./fix-pod.sh` (Podman). See
[notes.md](notes.md).

**Port 8080 already in use**
Something else owns the port. Stop it, or (Podman) run on another port:
`HOST_PORT=9000 ./pod.sh --fresh` and open `http://cloud.test:9000`.

**Browser can't resolve `cloud.test`**
Re-check Step 1. On Windows make sure you edited the hosts file as Administrator.

---

## What's in here

| File | Purpose |
|------|---------|
| `docker-compose.yaml` | Docker stack definition |
| `pod.sh` | Podman imperative build script |
| `nextcloud-kube.yaml` | Podman `play kube` manifest |
| `nginx.conf` / `nginx.pod.conf` | Reverse-proxy config (Docker / Podman) |
| `hooks/before-starting/office.sh` | Auto-installs & configures Collabora Office |
| `start.sh` | Convenience wrapper for `docker compose up -d` |
| `fix.sh` / `fix-pod.sh` | Break-glass fix for App Store caching issues |
| `notes.md` | Architecture deep-dive: *why* it's built this way |

For the design rationale (the `.test` domain, the nginx split-hostname trick, the
port invariant), read **[notes.md](notes.md)**.
