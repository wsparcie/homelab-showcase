#!/usr/bin/env python3
"""Pin compose images to the digest of the image each running container uses right now.

`image: repo:tag` becomes `image: repo:tag@sha256:<digest>  # pinned <date>, version <label>`. The running containers
keep running (nothing is pulled or recreated); the next `docker compose up/pull` uses exactly the same image until
the digest is changed on purpose. Every touched file gets a `.bak-pin-<date>` copy and a `docker compose config -q` check.
Usage (inside a Docker host):  pin-images.py [--apply]     (dry run without --apply)
"""
import json, os, re, shutil, subprocess, sys, datetime
APPLY = "--apply" in sys.argv
TODAY = datetime.date.today().isoformat()
def sh(*a): return subprocess.run(a, capture_output=True, text=True).stdout
ids = sh("docker", "ps", "-q").split()
by_file = {}
for c in json.loads(sh("docker", "inspect", *ids)) if ids else []:
    L = c["Config"].get("Labels") or {}
    files = L.get("com.docker.compose.project.config_files", "")
    svc = L.get("com.docker.compose.service")
    ref = c["Config"]["Image"]
    if not files or not svc or "@sha256:" in ref:
        continue
    img = json.loads(sh("docker", "image", "inspect", c["Image"]))[0]
    repo = ref.rsplit(":", 1)[0] if ":" in ref.split("/")[-1] else ref
    digests = [d for d in img.get("RepoDigests") or [] if d.split("@")[0] in (repo, "docker.io/" + repo, "docker.io/library/" + repo, repo.replace("docker.io/library/", ""), repo.replace("docker.io/", ""))]
    if not digests:
        print(f"  skip {svc}: {ref} has no registry digest (locally built?)"); continue
    digest = digests[0].split("@")[1]
    ver = (img.get("Config", {}).get("Labels") or {}).get("org.opencontainers.image.version", "")
    for f in files.split(","):
        if f.startswith("/data/compose/"):   # Portainer stacks: path inside the Portainer container
            f = "/var/lib/docker/volumes/portainer_data/_data/compose/" + f[len("/data/compose/"):]
        by_file.setdefault(f, []).append((svc, ref, digest, ver))
changed = 0
for f, items in by_file.items():
    if not os.path.exists(f):
        print(f"  missing file {f}"); continue
    s = open(f).read(); orig = s
    for svc, ref, digest, ver in items:
        pat = re.compile(r"(?m)^(\s*image:\s*[\"']?)" + re.escape(ref) + r"([\"']?)[ \t]*(#.*)?$")
        n = len(pat.findall(s))
        if n != 1:
            print(f"  {os.path.basename(os.path.dirname(f))}/{svc}: '{ref}' found {n}x in compose, left alone"); continue
        note = f"  # pinned {TODAY}" + (f", version {ver}" if ver else "")
        s = pat.sub(lambda m: f"{m.group(1)}{ref}@{digest}{m.group(2)}{note}", s)
        print(f"  {svc}: {ref} -> @{digest[:19]}… {ver}")
    if s != orig:
        changed += 1
        if APPLY:
            shutil.copy2(f, f"{f}.bak-pin-{TODAY}")
            open(f, "w").write(s)
            d = os.path.dirname(f); env = [a for e in ("stack.env", ".env") if os.path.exists(os.path.join(d, e)) for a in ("--env-file", os.path.join(d, e))]
            r = subprocess.run(["docker", "compose", "-f", f, *env, "config", "-q"], capture_output=True, text=True, cwd=d)
            if r.returncode:
                shutil.copy2(f"{f}.bak-pin-{TODAY}", f)
                print(f"  !! {f}: compose config failed, restored: {r.stderr.strip()[:200]}")
            else:
                print(f"  ok {f}")
print(f"{'applied' if APPLY else 'dry run'}: {changed} compose files to change")
