#!/bin/sh
# Prints a JSON summary of all containers on this Docker host: image, state, ports, mounts, restart policy,
# networks, compose labels and environment (redact.py removes secret values afterwards). Run inside a guest.
command -v docker >/dev/null 2>&1 || exit 0
ids=$(docker ps -aq)
[ -n "$ids" ] || exit 0
docker inspect $ids | python3 -c '
import sys, json
out = []
for c in json.load(sys.stdin):
    cfg, hc, ns = c["Config"], c["HostConfig"], c["NetworkSettings"]
    out.append({
        "name": c["Name"].lstrip("/"), "image": cfg["Image"], "state": c["State"]["Status"],
        "restart": (hc.get("RestartPolicy") or {}).get("Name"),
        "ports": {k: [f"{b.get(\"HostIp\",\"\")}:{b[\"HostPort\"]}" for b in (v or [])] for k, v in (ns.get("Ports") or {}).items()},
        "mounts": [f"{m.get(\"Source\")}:{m.get(\"Destination\")}{\":ro\" if not m.get(\"RW\", True) else \"\"}" for m in c.get("Mounts", [])],
        "networks": sorted((ns.get("Networks") or {}).keys()),
        "compose": {k.split(".")[-1]: v for k, v in (cfg.get("Labels") or {}).items() if k in ("com.docker.compose.project", "com.docker.compose.service", "com.docker.compose.project.working_dir")},
        "env": sorted(e for e in (cfg.get("Env") or []) if not e.startswith(("PATH=", "HOME=", "LANG=", "GPG_KEY="))),
        "command": cfg.get("Cmd"), "privileged": hc.get("Privileged"), "cap_add": hc.get("CapAdd"),
    })
print(json.dumps(sorted(out, key=lambda x: x["name"]), indent=1))'
