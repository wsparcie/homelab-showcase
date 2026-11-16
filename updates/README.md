# Image pinning and updates

Write-up: [`docs/operations.md`](../docs/operations.md#pinned-images-and-an-update-procedure).

| File | Runs on | What it does |
|---|---|---|
| `pin-images.py [--apply]` | each Docker host | pins every running compose service to its current digest (backup `.bak-pin-<date>`, checked with `docker compose config -q`, nothing is restarted) |
| `image-check.py` | each Docker host | prints JSON lines: the pinned digest and the registry's digest for the same tag (manifest `HEAD`) |
| `image-format.py` | hypervisor | turns the output of `image-check.py` into a Markdown table |
| `image-updates` | hypervisor, weekly timer | runs the check in every Docker host container (`DOCKER_HOSTS`), writes the report and the metric, optionally posts to Discord |
| `update-service.py <container> <repo:tag>` | a Docker host | pulls, pins and recreates one service and waits until it's healthy. If `up` fails it restores the compose file |

How I update: pick updates that are at least two weeks old, read the release notes, run `update-service.py`, check the
app's health probe and write it down in the changelog. To roll back, put the previous digest back in the compose file
and run `docker compose up -d <service>`.
