# Architecture

Three containers behind an nginx reverse proxy:

- `http://cloud.localhost` → nginx → nextcloud-frontend:80
- `http://collabora.localhost` → nginx → collabora-backend:9980

nginx solves the split-hostname problem: the browser, Nextcloud, and Collabora all use
the same domain names, which resolve to 127.0.0.1 in Chrome/Firefox without needing
/etc/hosts changes (*.localhost is handled natively by modern browsers).

Credentials: damien / password

## Why nginx was needed

Without a reverse proxy there are three conflicting URL requirements:
1. Browser → Collabora: needs a hostname the browser can resolve (localhost)
2. Nextcloud → Collabora: needs a Docker-internal hostname (collabora-backend)
3. Collabora → Nextcloud WOPI callback: needs a hostname Collabora can reach inside Docker

nginx gives everyone a single consistent domain. The host also has UFW running with a
default DROP policy, which blocked Docker container → host traffic, ruling out the
simpler network_mode:host approach for Collabora.


# Post-Startup Setup

After `docker-compose up -d`, do the following once in the Nextcloud UI.

## Step 1 — Fix the app store (if it says "couldn't find any apps")

Run `./fix.sh`, then refresh the browser.

## Step 2 — Install Nextcloud Office app

Go to: `http://cloud.localhost/index.php/settings/apps` → search **"Nextcloud Office"** → click **Enable**.

## Step 3 — Configure it to use Collabora

Go to: `http://cloud.localhost/settings/admin/richdocuments`

Select **"Use your own server"** and enter:

```
http://collabora.localhost
```

Set the **WOPI allow list** to:

```
172.16.0.0/12
```

Click **Save**. It should show a green "Collabora Online is reachable" confirmation.

## Step 4 — Open an ODT or DOCX file

Upload any `.odt` or `.docx` file and click it. It should open in the embedded editor.

> Access Nextcloud at http://cloud.localhost (not localhost:8080)
