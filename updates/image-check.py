#!/usr/bin/env python3
"""Runs inside a Docker host: for every pinned compose image (repo:tag@sha256:...) used by a running container,
compare the pinned digest with the registry's current digest for the same tag. Prints JSON lines."""
import json, os, re, subprocess, urllib.request, urllib.error
ACCEPT = ", ".join(["application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json",
                    "application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"])

def split_ref(ref):
    name, tag = (ref.rsplit(":", 1) if ":" in ref.split("/")[-1] else (ref, "latest"))
    first = name.split("/")[0]
    if "." in first or ":" in first or first == "localhost":
        host, repo = first, name.split("/", 1)[1]
    else:
        host, repo = "registry-1.docker.io", name
        if repo.startswith("docker.io/"): repo = repo[10:]
        if "/" not in repo: repo = "library/" + repo
    if host == "docker.io": host = "registry-1.docker.io"
    return host, repo, tag

def registry_digest(ref):
    """HEAD the manifest (Docker Hub does not count HEAD against the pull rate limit); anonymous bearer token."""
    host, repo, tag = split_ref(ref)
    url = f"https://{host}/v2/{repo}/manifests/{tag}"
    def head(token=None):
        h = {"Accept": ACCEPT}
        if token: h["Authorization"] = f"Bearer {token}"
        return urllib.request.urlopen(urllib.request.Request(url, method="HEAD", headers=h), timeout=20)
    try:
        return head().headers["Docker-Content-Digest"]
    except urllib.error.HTTPError as e:
        if e.code != 401: raise
        ch = dict(re.findall(r'(\w+)="([^"]*)"', e.headers.get("WWW-Authenticate", "")))
        q = f"{ch['realm']}?service={ch.get('service','')}&scope={ch.get('scope', f'repository:{repo}:pull')}"
        tok = json.load(urllib.request.urlopen(q, timeout=20))
        return head(tok.get("token") or tok.get("access_token")).headers["Docker-Content-Digest"]
def sh(*a, t=60):
    try: return subprocess.run(a, capture_output=True, text=True, timeout=t).stdout
    except subprocess.TimeoutExpired: return ""
ids = sh("docker", "ps", "-q").split()
files = set()
for c in (json.loads(sh("docker", "inspect", *ids)) if ids else []):
    for f in ((c["Config"].get("Labels") or {}).get("com.docker.compose.project.config_files") or "").split(","):
        if f.startswith("/data/compose/"): f = "/var/lib/docker/volumes/portainer_data/_data/compose/" + f[14:]
        if f: files.add(f)
seen = set()
for f in sorted(files):
    if not os.path.exists(f): continue
    for m in re.finditer(r"(?m)^\s*image:\s*[\"']?([^\s\"'@]+)@(sha256:[0-9a-f]{64})[\"']?(?:\s*#.*?version ([^\s,]+))?", open(f).read()):
        ref, pinned, pinned_ver = m.group(1), m.group(2), m.group(3) or ""
        if (ref, pinned) in seen: continue
        seen.add((ref, pinned))
        try: latest = registry_digest(ref)
        except Exception as e: print(json.dumps({"image": ref, "error": f"registry lookup failed ({str(e)[:60]})"})); continue
        new_ver = new_created = ""
        try:
            li = json.loads(sh("docker", "image", "inspect", f"{ref}@{pinned}"))[0]
            pinned_created = li.get("Created", "")[:10]
            pinned_ver = pinned_ver or (li.get("Config", {}).get("Labels") or {}).get("org.opencontainers.image.version", "")
        except Exception:
            pinned_created = ""
        if latest != pinned:
            try:
                img = json.loads(sh("docker", "buildx", "imagetools", "inspect", ref, "--format", "{{json .Image}}"))
                if "config" not in img: img = img.get("linux/amd64", next(iter(img.values())))
                new_ver = (img.get("config", {}).get("Labels") or {}).get("org.opencontainers.image.version", "")
                new_created = (img.get("created") or "")[:10]
                new_created = img.get("created", "")[:10]
            except Exception: pass
        print(json.dumps({"image": ref, "file": f, "pinned_version": pinned_ver, "update": latest != pinned, "new_version": new_ver,
                          "pinned_created": pinned_created, "new_created": new_created}))
