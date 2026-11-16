#!/bin/bash
# Nightly export of homelab configuration into a private Git repo (directory live/).
# Runs on pve as root. Collects config files only (no databases, media, keys), redacts secrets
# (redact.py), refuses to commit if gitleaks still finds anything, then commits and pushes the diff.
#
#   /root/homelab-export/export.sh            # collect + redact + scan + commit + push
#   /root/homelab-export/export.sh --dry-run  # collect + redact + scan only
set -uo pipefail
BASE=/root/homelab-export
REPO=$BASE/repo
OUT=$REPO/live
STAGE=$BASE/stage
DRY=${1:-}
LOG() { echo "[$(date +%H:%M:%S)] $*"; }

# ct <vmid> <dest> <path...>: config files out of a container (filter: collect-files.sh)
ct() {
  local id=$1 dest=$2; shift 2
  mkdir -p "$STAGE/$dest"
  pct push "$id" $BASE/collect-files.sh /tmp/collect-files.sh >/dev/null 2>&1 || { LOG "CT $id: push failed"; return; }
  pct exec "$id" -- sh /tmp/collect-files.sh "$@" | tar -xf - -C "$STAGE/$dest" 2>/dev/null
  pct exec "$id" -- rm -f /tmp/collect-files.sh
  if pct exec "$id" -- sh -c 'command -v docker' >/dev/null 2>&1; then
    pct push "$id" $BASE/docker-inventory.sh /tmp/docker-inventory.sh >/dev/null 2>&1
    pct exec "$id" -- sh /tmp/docker-inventory.sh > "$STAGE/$dest/docker-inventory.json" 2>/dev/null; pct exec "$id" -- rm -f /tmp/docker-inventory.sh
  fi
  LOG "CT $id -> $dest: $(find "$STAGE/$dest" -type f | wc -l) files"
}
# vm <vmid> <dest> <path...>: same through the guest agent (base64 tar in out-data)
vm() {
  local id=$1 dest=$2; shift 2
  mkdir -p "$STAGE/$dest"
  pvesh create /nodes/pve/qemu/$id/agent/file-write --file /tmp/collect-files.sh --content "$(base64 -w0 $BASE/collect-files.sh)" --encode 0 >/dev/null 2>&1     || { LOG "VM $id: guest agent unavailable"; return; }
  qm guest exec "$id" --timeout 180 -- env B64=1 sh /tmp/collect-files.sh "$@" 2>/dev/null     | python3 -c 'import sys,json,base64; d=json.load(sys.stdin); sys.stdout.buffer.write(base64.b64decode(d.get("out-data","")))'     | tar -xf - -C "$STAGE/$dest" 2>/dev/null
  qm guest exec "$id" -- rm -f /tmp/collect-files.sh >/dev/null 2>&1
  if [ "${DOCKER_VM:-}" = 1 ]; then
    pvesh create /nodes/pve/qemu/$id/agent/file-write --file /tmp/docker-inventory.sh --content "$(base64 -w0 $BASE/docker-inventory.sh)" --encode 0 >/dev/null 2>&1
    qm guest exec "$id" --timeout 60 -- sh /tmp/docker-inventory.sh 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("out-data",""))' > "$STAGE/$dest/docker-inventory.json"
    qm guest exec "$id" -- rm -f /tmp/docker-inventory.sh >/dev/null 2>&1
  fi
  LOG "VM $id -> $dest: $(find "$STAGE/$dest" -type f | wc -l) files"
}

rm -rf "$STAGE"; mkdir -p "$STAGE"

# ---- pve host ------------------------------------------------------------------------------
H=$STAGE/pve; mkdir -p $H/etc-pve $H/etc $H/snippets $H/root-scripts $H/systemd
( cd /etc/pve && cp -r --parents qemu-server lxc firewall storage.cfg datacenter.cfg jobs.cfg vzdump.cron replication.cfg \
    user.cfg domains.cfg notifications.cfg ha 2>/dev/null $H/etc-pve/ )
cp /etc/network/interfaces /etc/hosts /etc/resolv.conf /etc/vzdump.conf /etc/crontab $H/etc/ 2>/dev/null
cp -r /etc/cron.d $H/etc/ 2>/dev/null; cp -r /etc/modprobe.d /etc/sysctl.d /etc/udev/rules.d $H/etc/ 2>/dev/null
cp /var/lib/vz/snippets/* $H/snippets/ 2>/dev/null
find /root -maxdepth 2 -type f \( -name '*.sh' -o -name '*.py' \) -size -256k ! -path '/root/homelab-export/*' -exec cp {} $H/root-scripts/ \; 2>/dev/null
find /etc/systemd/system -maxdepth 2 -type f \( -name '*.service' -o -name '*.timer' -o -name '*.conf' \) -newer /etc/hostname -exec cp --parents {} $H/systemd/ \; 2>/dev/null
pveversion -v > $H/pveversion.txt 2>/dev/null; zpool status > $H/zpool-status.txt 2>/dev/null; zfs list -o name,used,avail,mountpoint > $H/zfs-list.txt 2>/dev/null
pct list > $H/pct-list.txt; qm list > $H/qm-list.txt
LOG "pve: $(find $H -type f | wc -l) files"

set -f   # globs in the source lists expand inside each guest, not on pve
# ---- containers ------------------------------------------------------------------------------
# Examples - one line per guest: ct|vm <vmid> <output dir> <paths or globs inside the guest...>
ct 100 ct100-docker   /var/lib/docker/volumes/portainer_data/_data/compose /opt/appdata/homepage/config   '/opt/appdata/*arr/config.xml' /opt/appdata/npm/data/nginx/proxy_host /etc/systemd/system/*.service
ct 600 ct600-monitoring /opt/appdata/monitoring/docker-compose.yml /opt/appdata/prometheus /opt/appdata/grafana-provisioning
ct 710 ct710-llm-gateway /opt/litellm/compose.yaml /opt/litellm/config.yaml

# ---- VMs (guest agent) -----------------------------------------------------------------------
HA=/mnt/data/supervisor/homeassistant
vm 300 vm300-home-assistant $HA/configuration.yaml $HA/automations.yaml $HA/scripts.yaml $HA/packages
DOCKER_VM=1 vm 400 vm400-ai /opt/*/docker-compose.yml /etc/systemd/system/*.service
vm 800 vm800-wazuh /var/ossec/etc/ossec.conf /var/ossec/etc/rules /var/ossec/etc/decoders
vm 810 vm810-ids /etc/suricata/suricata.yaml /opt/zeek/etc /opt/zeek/share/zeek/site/local.zeek

set +f
# ---- redact, scan, publish -------------------------------------------------------------------
python3 $BASE/redact.py "$STAGE" || { LOG "redaction failed"; exit 1; }
python3 $BASE/scan.py "$STAGE" > $BASE/scan.txt; RC=$?
if [ -x $BASE/gitleaks ]; then   # optional third gate if gitleaks is installed
  $BASE/gitleaks detect --no-git --source "$STAGE" --no-banner --redact -c $BASE/gitleaks.toml >> $BASE/scan.txt 2>&1 || RC=1
fi
if [ $RC -ne 0 ]; then LOG "POSSIBLE SECRETS - nothing committed (details: $BASE/scan.txt, masked)"; tail -40 $BASE/scan.txt; exit 2; fi
LOG "scan: clean ($(find "$STAGE" -type f | wc -l) files)"
[ "$DRY" = "--dry-run" ] && { LOG "dry run, staged in $STAGE"; exit 0; }

cd "$REPO"
export GIT_SSH_COMMAND="ssh -i $BASE/deploy_key -o IdentitiesOnly=yes -o UserKnownHostsFile=$BASE/known_hosts"
git pull -q --rebase origin main 2>/dev/null || true
rm -rf "$OUT"; mkdir -p "$OUT"; cp -a "$STAGE"/. "$OUT"/
git add -A live
if git diff --cached --quiet; then LOG "no changes"; exit 0; fi
git -c user.name="pve export" -c user.email="export@pve.example.lan" commit -q -m "live: config export $(date +%F)" -m "$(git diff --cached --stat | tail -1)"
git push -q origin HEAD:main && LOG "pushed $(git rev-parse --short HEAD)"
