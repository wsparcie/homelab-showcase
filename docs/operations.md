# Operations: catching silent failures, backups that leave nightly, pinned images

The architecture was fine early on. What needed work was the boring part: knowing when something quietly stops,
losing at most a day of the data that matters, and making upgrades a decision instead of a side effect of a restart.

## Silent failures

Every published service had an HTTP probe for its front page. That answers "does the reverse proxy return something",
not "does the app work". Three real cases slipped through:

- a firewall rule on the app platform blocked one app's backend for two weeks while its front page returned 200;
- a laptop's file backups had not finished in weeks (the server was fine, the client was not);
- the IDS sensor was losing packets (see [`network-security.md`](network-security.md)).

### App health probes

Each app is probed on its own health endpoint, **through the reverse proxy** (the same path users take), with three
blackbox modules ([`monitoring/app-health/`](../monitoring/app-health)):

| Module | Passes when | Used for |
|---|---|---|
| `http_health_ok` | 200 **and** the body says `"status": "ok"/"pass"/"up"/true` | apps whose health endpoint checks the DB / backend |
| `http_2xx` | 200 | endpoints that only return a status code (`/alive`, `/ping`, `status.php`) |
| `http_backend_alive` | 200/401/403/404 **with** a JSON `statusCode` body | APIs that need auth; proves the backend answered, not the proxy's 502 page |

One Grafana rule covers all targets: failing for 5 minutes, **or no data**, fires. Adding an app is one line in the
target file.

### Dead-man's switch

Monitoring that runs on the box it monitors cannot report its own death. A watchdog
([`monitoring/watchdog/`](../monitoring/watchdog)) runs every 5 minutes next to Prometheus and pings an external
healthchecks service only if:

- Prometheus is ready **and** has a fresh sample from the hypervisor's node exporter (< 3 min old),
- Grafana's health endpoint reports its database ok,
- the blackbox exporter is healthy.

Otherwise it sends `/fail` with the reasons. If the host, the power or the uplink dies, the pings stop and the alert
comes from outside the house. Both off-site backup jobs ping their own checks (`/start`, then the exit code), so a
backup that never ran is as visible as one that failed.

## Backups: the critical state leaves every night

Layers: ZFS snapshots (hourly/daily), a daily `vzdump` of every guest, a weekly encrypted restic copy to a second site.
Weekly is fine for photos. For the git server, the password vault and the AI gateway (provider keys, virtual keys,
spend DB) it meant up to seven days of loss.

[`backup/critical-offsite`](../backup/critical-offsite) runs daily:

1. one atomic `zfs snapshot` of the three containers' root datasets: the SQLite databases (with WAL) are
   crash-consistent without stopping anything;
2. `pg_dump` of the gateway's Postgres;
3. restic backup of the snapshot paths (fixed snapshot name, so restic sees identical paths every day and
   deduplicates); keep 14 daily, 8 weekly, 6 monthly;
4. a metric for Prometheus and a healthchecks ping with the exit code.

A restore drill has been done (a container and a VM from vzdump into an isolated network, a file from the off-site
repository); it is meant to become a habit.

## Pinned images and an update procedure

Most containers followed `:latest`. A restart could become an upgrade, and nobody knew what version was running.

[`updates/`](../updates):

- `pin-images.py` pins every running compose service to the digest it runs now (`repo:tag@sha256:…`; the tag stays
  for readability). Works with Portainer stacks (maps `/data/compose/<id>` to the host path). Dry run by default.
- `image-check.py` compares each pinned digest with the registry's current digest for the same tag, with a manifest
  `HEAD` and an anonymous token (Docker Hub does not count `HEAD` against the pull limit).
- `image-updates` runs weekly on the hypervisor over all Docker hosts: Markdown report, a Prometheus metric, optional
  Discord post. Nothing is pulled.
- `update-service.py <container> <repo:tag>` pulls, pins tag + digest in the right compose file (backup copy), recreates
  only that service and waits for it to be healthy.

Policy: a release must be **two weeks old** (unless it fixes a security issue), majors one at a time, release notes
first, rollback = old digest back + `up -d`.

## Moving the vault and the git server out of the big container

One Docker host carried ~60 services. A hole in any media app would have been one step from the password vault's
files. The vault and the git server now run in their own small unprivileged containers, each with a default-deny
firewall that admits only the reverse proxy and the few clients that need it.

What the moves taught me:

- **`$` in compose values is interpolated.** A `$Abc…` inside a password or an Argon2 hash becomes an empty string
  with only a warning. The vault's admin token had been silently truncated since it was deployed; a wiki's DB
  password too (it worked only because the DB and the app were truncated identically). Escape as `$$`, or keep secrets
  in an env file.
- **UID mapping differs between containers.** Data copied from a container with a different ID mapping keeps the
  numeric owners; the app could not even write its config until every file was shifted into the new range.
- **Find every client of the old address first.** Deploy platform, submodule URLs (now relative, `../repo.git`),
  editors, the nightly export, firewall rules. A small socket forwarder on the old SSH port keeps anything missed
  working during the transition.
- **Keep host keys.** SSH host keys were copied with the data, so no client saw a key change.
- **Image transfer without the registry:** `docker save | docker load` between hosts avoided a Docker Hub rate limit
  hit earlier the same day.

Downtime: 9 seconds for the vault, about 3 minutes for the git server.
