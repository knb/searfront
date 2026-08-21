# Daily SearXNG Maintenance

This procedure updates a Compose-managed SearXNG instance daily, rotates its search engines, and verifies search
after each update.

## Prerequisites

- SearXNG runs from the official Compose layout.
- `settings.yml` is mounted from a persistent host file.
- The maintenance user can operate Docker.
- Neither searfront nor SearXNG is publicly exposed.

The command follows the official service update flow: `docker compose pull`, then `docker compose up -d`. It does
not update the Compose template itself; review and apply upstream template changes manually.

## Configuration

```sh
cp config/searxng-maintenance.env.example .env.searxng-maintenance
chmod 600 .env.searxng-maintenance
```

Set deployment-specific paths and rotation groups:

```sh
SEARXNG_COMPOSE_FILE=/home/kensei/sites/searxng/compose.yaml
SEARXNG_SETTINGS_PATH=/home/kensei/sites/searxng/core-config/settings.yml
SEARXNG_BASE_URL=http://127.0.0.1:8080/
SEARXNG_ENGINE_ROTATIONS="google,duckduckgo;bing,brave;qwant,mojeek"
```

Semicolons separate daily groups; commas separate engines within a group. Names must exactly match current
SearXNG engine names. The rotation script preserves other settings, updates
`use_default_settings.engines.keep_only`, and enables HTML/JSON formats for the smoke test.

The Compose image field must allow the maintenance command to select latest and rollback images:

```yaml
image: ${SEARXNG_IMAGE:-docker.io/searxng/searxng:latest}
```

Set `SEARXNG_HEALTH_MODE=compose` when SearXNG is intentionally not published on the host. Health and smoke
requests then run against loopback from inside the container without adding a public port.

## Manual verification

Run this before enabling the timer:

```sh
script/searxng-maintenance
```

The command locks against concurrent runs, backs up settings and rotation state, tags the current image for
rollback, rotates engines, pulls and recreates SearXNG, then checks HTTP health and a JSON search. If
`SEARFRONT_BASE_URL` and `SEARFRONT_TOKEN` are set, it also runs the end-to-end searfront smoke test. Any failure
restores the previous settings and rotation state and recreates the service from the rollback image.

## systemd user timer

```sh
mkdir -p ~/.config/systemd/user
cp deploy/systemd/user/searxng-maintenance.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now searxng-maintenance.timer
```

The default schedule is 04:20 daily with up to 30 minutes of randomized delay. `Persistent=true` runs a missed
maintenance window after the host starts again.

```sh
systemctl --user list-timers searxng-maintenance.timer
journalctl --user -u searxng-maintenance.service
```

For a root-owned production deployment under `/srv/searfront`, use the system units instead:

```sh
sudo cp deploy/systemd/system/searxng-maintenance.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now searxng-maintenance.timer
```

Test every engine group manually before unattended operation. Compare CAPTCHA, 429, insufficient-result, and
latency metrics by engine. Stop the timer if automatic rollback cannot restore a passing smoke test. This workflow
does not solve CAPTCHAs, spoof browser fingerprints, or implement bot evasion.
