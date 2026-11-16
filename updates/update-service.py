#!/usr/bin/env python3
"""Update one compose service to a pinned version: update-service.py <container_name> <repo:tag>
Pulls repo:tag, pins it as repo:tag@sha256:<digest> in the service's compose file (backup .bak-upd-<date>),
recreates only that service with docker compose (same project, same env file) and waits for it to run."""
import datetime, json, os, re, shutil, subprocess, sys, time
name, target = sys.argv[1], sys.argv[2]
def run(*a, check=True):
    r = subprocess.run(a, capture_output=True, text=True)
    if check and r.returncode: sys.exit(f"!! {' '.join(a[:4])}: {r.stderr.strip()[-400:]}")
    return r.stdout
c = json.loads(run("docker", "inspect", name))[0]; L = c["Config"]["Labels"]
proj, svc, f = L["com.docker.compose.project"], L["com.docker.compose.service"], L["com.docker.compose.project.config_files"].split(",")[0]
if f.startswith("/data/compose/"): f = "/var/lib/docker/volumes/portainer_data/_data/compose/" + f[14:]
old_ref = c["Config"]["Image"]
print(f"{name}: project={proj} service={svc} file={f}\n  old: {old_ref}")
run("docker", "pull", "-q", target)
repo = target.rsplit(":", 1)[0]
dig = [d.split("@")[1] for d in json.loads(run("docker", "image", "inspect", target))[0]["RepoDigests"]
       if d.split("@")[0] in (repo, "docker.io/" + repo, "docker.io/library/" + repo)][0]
new_ref = f"{target}@{dig}"
s = open(f).read()
pat = re.compile(r"(?m)^(\s*image:\s*[\"']?)" + re.escape(old_ref) + r"(?:@sha256:[0-9a-f]{64})?([\"']?)[ \t]*(#.*)?$")
if len(pat.findall(s)) != 1: sys.exit(f"!! old image found {len(pat.findall(s))}x in {f}")
today = datetime.date.today().isoformat()
shutil.copy2(f, f"{f}.bak-upd-{today}")
open(f, "w").write(pat.sub(lambda m: f"{m.group(1)}{new_ref}{m.group(2)}  # updated {today}", s))
d = os.path.dirname(f); env = [x for e in ("stack.env", ".env") if os.path.exists(os.path.join(d, e)) for x in ("--env-file", os.path.join(d, e))]
r = subprocess.run(["docker", "compose", "-p", proj, "-f", f, *env, "up", "-d", "--no-deps", svc], capture_output=True, text=True, cwd=d)
if r.returncode:
    shutil.copy2(f"{f}.bak-upd-{today}", f); sys.exit(f"!! compose up failed, compose file restored: {r.stderr[-400:]}")
for _ in range(60):
    st = json.loads(run("docker", "inspect", name, check=False) or "[{}]")[0].get("State", {})
    h = (st.get("Health") or {}).get("Status")
    if st.get("Running") and h in (None, "healthy"): break
    time.sleep(5)
print(f"  new: {new_ref}\n  state: running={st.get('Running')} health={h} restarts={st.get('RestartCount', '?')}")
