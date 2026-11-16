# Image pinning and updates

Write-up: [`docs/operations.md`](../docs/operations.md#pinned-images-and-an-update-procedure).

| File | Runs on | What |
|---|---|---|
| `pin-images.py [--apply]` | each Docker host | pins every running compose service to its current digest (backup `.bak-pin-<date>`, `docker compose config -q` check, nothing restarted) |
| `image-check.py` | each Docker host | JSON lines: pinned digest vs the registry's digest for the same tag (manifest `HEAD`) |
| `image-format.py` | hypervisor | turns `image-check.py` output into a Markdown table |
| `image-updates` | hypervisor, weekly timer | runs the check in every Docker host container (`DOCKER_HOSTS`), report + metric + optional Discord |
| `update-service.py <container> <repo:tag>` | a Docker host | pull, pin, recreate one service, wait for healthy; restores the compose file if `up` fails |

Procedure: pick updates at least two weeks old, read release notes, `update-service.py`, check the app's health probe,
note it in the changelog. Rollback: previous digest back in the compose file, `docker compose up -d <service>`.
