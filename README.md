# sites-config

Hosting config for my personal sites, all on one DigitalOcean droplet running Docker Compose with Caddy in front.

| Site | Service | Runs |
|---|---|---|
| wtc.wingnutstables.com | `wtc-intranet` | always |
| fadretreat.com (+ www, test) | `fadretreat` | always |
| www.groop.zone, www.groopzone.com, www.wingnutstables.com (+ test, chicharron) | `groopzone` | always |
| hunt.wingnutstables.com | `wingnut-hunt` | only during events |

## The server

- **Droplet:** `sites-nyc3-1`, NYC3, Premium Intel 2 GB / 2 vCPU, Ubuntu 26.04 LTS
- **Public IP:** 157.245.13.34 · **Private IP:** 10.132.0.2
- **Login:** `ssh deploy@157.245.13.34` (root and password login are off)
- **Config lives in:** `/opt/sites` (a clone of this repo)
- **Database:** DigitalOcean Managed MySQL, also NYC3. Apps connect to its **private** hostname (starts with `private-`), port 25060, TLS required. The droplet is in the database's Trusted Sources.
- **Cloudflare:** sites are proxied (orange cloud), SSL mode **Full (strict)**. Caddy gets its certificates through Cloudflare DNS (API token in `env/caddy.env`), so renewals work whether a record is proxied or not, and it trusts Cloudflare's IP ranges so apps see real visitor IPs.
- **Security updates** install automatically; the server reboots itself at 04:30 UTC when an update needs it, and the containers come back on their own.

## What's in here

```
compose.yaml          every app, plus Caddy
caddy/Caddyfile       which hostname goes to which app; Caddy handles HTTPS
caddy-image/          builds Caddy with the Cloudflare plugins
env/*.env.example     list of secrets each app needs (no real values)
systemd/              timers for GroopZone's scheduled jobs
setup-droplet.sh      one-time setup for a brand-new droplet
```

**Not in git, only on the server:**

- `env/<app>.env` — the real secrets (`chmod 600`)
- `certs/` — the database CA certificate, mounted into apps at `/etc/ssl/do`

---

## Everyday tasks

All server commands run in `/opt/sites` as `deploy`.

### Change the config (compose.yaml or Caddyfile)

On the Mac:

```bash
# edit, then
git commit -am "what changed"
git push
```

On the server:

```bash
cd /opt/sites
git pull
docker compose up -d            # applies compose.yaml changes; untouched apps keep running
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile   # only if the Caddyfile changed
```

The Caddy reload is seamless — no dropped requests. If Caddy rejects the new Caddyfile, it keeps running the old one and prints the error.

### Deploy a new version of an app

Image versions are pinned in `compose.yaml`, so git records what's running.

1. Build and push the new image from the app's own repo as usual (e.g. `wtc-intranet:3.0.8`).
2. Change the tag in `compose.yaml`, commit, push.
3. On the server:
   ```bash
   cd /opt/sites && git pull
   docker compose pull wtc-intranet
   docker compose up -d wtc-intranet
   ```

To roll back: put the old tag back and repeat.

### Change a secret

Secrets aren't in git, so edit them on the server, then recreate that app:

```bash
nano env/wtc-intranet.env
docker compose up -d --force-recreate wtc-intranet
```

(`restart` is not enough — env files are only read when the container is created.)

### Logs, status, restart

```bash
docker compose ps                       # what's running
docker compose logs -f wtc-intranet     # follow one app (Ctrl-C to stop)
docker compose logs --tail 100 caddy    # recent Caddy output, e.g. certificate problems
docker compose restart wtc-intranet
docker stats --no-stream                # memory/CPU per container
```

### Wingnut Hunt for an event

Hunt is on the `events` profile, so a normal `docker compose up -d` leaves it off.

```bash
docker compose --profile events up -d wingnut-hunt    # start for the event
docker compose stop wingnut-hunt                       # stop afterwards
```

### Scheduled jobs (GroopZone notifications)

Three systemd timers run GroopZone's notification scripts, replacing the old k8s CronJobs. Times are Eastern; daylight saving is handled.

| Timer | When | Runs |
|---|---|---|
| `gz-daily-notify` | 10:00 daily | `notification_email.js low` |
| `gz-hourly-notify` | every hour | `notification_email.js high` |
| `gz-news-notify` | every 30 min | `article_notifications.js` |

Each run is `docker compose run --rm groopzone-job <script>` — a fresh container from the groopzone image, same secrets and DB certificate, removed afterwards. A run won't start while the previous one is still going. The job image tag in `compose.yaml` (`groopzone-job`) should normally match the app's.

```bash
systemctl list-timers 'gz-*'                     # next and last run of each
journalctl -u gz-hourly-notify -n 50             # output of recent runs
sudo systemctl start gz-news-notify              # run one now, by hand
```

Install or update the timers after changing anything in `systemd/`:

```bash
sudo cp /opt/sites/systemd/gz-* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gz-daily-notify.timer gz-hourly-notify.timer gz-news-notify.timer
```

To pause one: `sudo systemctl stop gz-news-notify.timer` (and `disable` to keep it off after reboots).

### Update Caddy itself

Caddy is built on the server (it needs the Cloudflare plugins), so it isn't pulled like the apps:

```bash
docker compose build --pull caddy
docker compose up -d caddy
```

### Clean up old images

Every deploy leaves the previous image on disk. Once in a while:

```bash
docker image prune -a      # removes images no container is using
```

---

## Adding a site

1. Add a service to `compose.yaml`. Copy an existing one: `restart: unless-stopped`, an `env_file`, `expose` (never `ports` — see below), a `mem_limit`.
2. Add a block to `caddy/Caddyfile`:
   ```
   example.com {
   	reverse_proxy example-app:3000
   }
   ```
3. Add `env/example-app.env.example` listing the secrets it needs.
4. Commit and push. On the server: `git pull`, create `env/example-app.env` with real values, `chmod 600` it, then `docker compose up -d` and reload Caddy.
5. In Cloudflare, add an A record pointing at 157.245.13.34, **proxied** (orange cloud), and check the zone's SSL mode is **Full (strict)**. Make sure the Cloudflare API token in `env/caddy.env` covers that zone (new domain = edit the token's zone list). Caddy logs `certificate obtained successfully` on the first request.

**Never give an app `ports:`.** Docker opens published ports straight through the firewall (it bypasses ufw). Only Caddy publishes ports; apps use `expose` and are reached through Caddy.

---

## Building a new server from scratch

Data lives in the managed database, so a new droplet is only config. About an hour.

1. Create the droplet: NYC3, **same VPC as the database**, Ubuntu LTS, your SSH key, monitoring on. Check the SSH key the panel selects really is the Mac's (`ssh-keygen -lf ~/.ssh/id_rsa.pub -E md5` against Settings → Security → SSH Keys).
2. Add the droplet to the database's **Trusted Sources**.
3. Copy and run the setup script:
   ```bash
   scp setup-droplet.sh root@<ip>:
   ssh root@<ip> 'bash setup-droplet.sh'
   ```
   Confirm `ssh deploy@<ip>` works in a second terminal before closing the root session. Reboot if `/var/run/reboot-required` exists.
4. Give the server read access to this repo (a GitHub **deploy key**):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/sites-config -N "" -C "sites-nyc3-1"
   cat ~/.ssh/sites-config.pub
   ```
   Add that key in GitHub → this repo → Settings → Deploy keys (read-only). Then:
   ```bash
   cat >> ~/.ssh/config <<'EOF'
   Host github.com
     IdentityFile ~/.ssh/sites-config
   EOF
   git clone git@github.com:dannygypsy/sites-config.git /opt/sites
   ```
5. Log Docker into GitHub's registry (token with `read:packages`):
   ```bash
   echo '<token>' | docker login ghcr.io -u dannygypsy --password-stdin
   ```
6. Recreate what isn't in git: each `env/<app>.env` and `env/caddy.env` (from the `.example` files) and `certs/` (download the CA from the database's Connection Details page, using the file name the apps expect).
7. `docker compose build caddy`, then `docker compose up -d`, check the logs, then move DNS over.
8. Install the scheduled-job timers (see "Scheduled jobs" above).

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Site shows a certificate error / Cloudflare 526 | Caddy couldn't get a certificate. `docker compose logs caddy`. Usually the Cloudflare API token is missing, expired, or doesn't cover that domain's zone. |
| Endless redirect loop | Cloudflare SSL mode is Flexible. Set it to **Full (strict)**. |
| App logs `HANDSHAKE_SSL_ERROR` | App can't find the DO CA. Check `certs/` has the file under the expected name. |
| App logs `ER_ACCESS_DENIED` / `ETIMEDOUT` to the DB | Using the public DB hostname, or the droplet isn't in Trusted Sources. |
| `Too many connections` | The managed DB allows 75 total across every app. Lower pool sizes. |
| Container keeps restarting | `docker compose logs <app>`; if it says `OOMKilled` in `docker inspect`, raise its `mem_limit`. |
| `docker compose pull` says unauthorized | ghcr.io login expired; redo step 5 above. |
