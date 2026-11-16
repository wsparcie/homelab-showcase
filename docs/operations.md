# Operations: silent failures, nightly off-site backups, pinned images

The services themselves worked. What I was missing was knowing when something quietly stops working, a backup recent
enough that I'd lose at most a day of the data that matters, and upgrades that happen only when I decide, not whenever
a container restarts.

## Silent failures

Every published service had an HTTP probe on its front page. That tells you the reverse proxy returns something, but
not that the app works. Three real problems went unnoticed this way:

- a firewall rule on the app platform blocked one app's backend for two weeks, and its front page kept returning 200;
- a laptop's file backups hadn't finished in weeks (the server was fine, the client wasn't);
- the IDS sensor was losing packets (see [`network-security.md`](network-security.md)).

### App health probes

Each app is now probed on its own health endpoint, through the reverse proxy, the same way users reach it. There are
three blackbox modules ([`monitoring/app-health/`](../monitoring/app-health)):

| Module | Passes when | Used for |
|---|---|---|
| `http_health_ok` | 200 and the body says `"status": "ok"/"pass"/"up"/true` | apps whose health endpoint checks the DB or the backend |
| `http_2xx` | 200 | endpoints that only return a status code (`/alive`, `/ping`, `status.php`) |
| `http_backend_alive` | 200/401/403/404 with a JSON `statusCode` body | APIs that need auth. A JSON answer means the backend replied, and it isn't the proxy's 502 page |

One Grafana rule covers all targets. It fires when a target fails for 5 minutes or when there is no data. Adding an
app means adding one line to the target file.

### Dead-man's switch

If monitoring runs on the same machine it watches, it can't tell anyone when that machine goes down. A watchdog
([`monitoring/watchdog/`](../monitoring/watchdog)) runs every 5 minutes next to Prometheus and pings an external
healthchecks service only when all of these are true:

- Prometheus is ready and has a sample from the hypervisor's node exporter that is less than 3 minutes old;
- Grafana's health endpoint says its database is ok;
- the blackbox exporter is healthy.

If any check fails it sends `/fail` with the reasons. If the host, the power or the internet connection goes down, the
pings stop and the alert comes from outside. Both off-site backup jobs ping their own checks too (`/start`, then the
exit code), so I find out about a backup that never ran as well as one that failed.

## Backups: the important data goes off-site every night

The layers are ZFS snapshots (hourly and daily), a daily `vzdump` of every guest, and a weekly encrypted restic copy to
another location. Weekly is fine for photos. For the git server, the password vault and the AI gateway (provider keys,
virtual keys, the spend database) it meant losing up to seven days.

[`backup/critical-offsite`](../backup/critical-offsite) runs daily:

1. One atomic `zfs snapshot` of the three containers' root datasets. The SQLite databases (with WAL) are
   crash-consistent and nothing has to be stopped.
2. `pg_dump` of the gateway's Postgres.
3. restic backup of the snapshot paths. The snapshot always has the same name, so restic sees the same paths every day
   and deduplicates them. Retention is 14 daily, 8 weekly and 6 monthly.
4. A metric for Prometheus and a healthchecks ping with the exit code.

I've done one restore test: a container and a VM from vzdump into an isolated network, and a file from the off-site
repository. I want to do it regularly.

## Pinned images and an update procedure

Most containers used `:latest`. A restart could quietly turn into an upgrade, and I didn't know which version was
running.

[`updates/`](../updates):

- `pin-images.py` pins every running compose service to the digest it's running now (`repo:tag@sha256:…`, the tag stays
  so it's readable). It works with Portainer stacks by mapping `/data/compose/<id>` to the path on the host. By default
  it only shows what it would change.
- `image-check.py` compares each pinned digest with the digest the registry has now for the same tag. It uses a manifest
  `HEAD` request with an anonymous token, and Docker Hub doesn't count `HEAD` against the pull limit.
- `image-updates` runs weekly on the hypervisor across all Docker hosts. It writes a Markdown report and a Prometheus
  metric, and can post to Discord. It doesn't pull anything.
- `update-service.py <container> <repo:tag>` pulls the image, pins tag and digest in the right compose file (keeping a
  backup copy), recreates only that service and waits until it's healthy.

My rules: a release has to be at least two weeks old unless it fixes a security issue, I do major versions one at a
time, and I read the release notes first. To roll back, I put the old digest back and run `up -d`.

## Moving the vault and the git server out of the big container

One Docker host was running about 60 services. A hole in any of the media apps would have put an attacker one step
away from the password vault's files. The vault and the git server now each run in their own small unprivileged
container. Their firewalls drop everything by default and let in only the reverse proxy and the few clients that need
access.

What I learned from the move:

- `$` in compose values gets interpolated. A `$Abc…` inside a password or an Argon2 hash becomes an empty string, and
  compose only prints a warning. The vault's admin token had been cut short ever since it was deployed. So had a wiki's
  database password, which worked only because the database and the app got the same truncated value. Escape it as
  `$$` or keep secrets in an env file.
- UID mapping differs between containers. Files copied from a container with a different ID mapping keep their numeric
  owners, and the app couldn't even write its config until I shifted every file into the new range.
- Before the move, find everything that uses the old address: the deploy platform, submodule URLs (now relative,
  `../repo.git`), editors, the nightly export, firewall rules. A small socket forwarder on the old SSH port keeps
  anything I missed working for now.
- I copied the SSH host keys along with the data, so no client saw a key change.
- I moved the images between hosts with `docker save | docker load`, because Docker Hub had already rate-limited me
  earlier that day.

Downtime was 9 seconds for the vault and about 3 minutes for the git server.
