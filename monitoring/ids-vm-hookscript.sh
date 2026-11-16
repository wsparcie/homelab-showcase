#!/bin/bash
# Proxmox hookscript for the IDS VM. The capture NIC (net1 -> tap<vmid>i1 on the mirror bridge) gets a
# 10000-packet host queue: with the default 1000, bursts on the port mirror overflowed it (~0.1% of
# mirrored packets dropped before the VM, which Zeek reported as 2-10% TCP capture loss).
vmid="$1"; phase="$2"
if [ "$phase" = "post-start" ]; then
    for i in $(seq 1 10); do
        ip link show "tap${vmid}i1" >/dev/null 2>&1 && break; sleep 1
    done
    ip link set "tap${vmid}i1" txqueuelen 10000 && echo "tap${vmid}i1 txqueuelen 10000"
fi
exit 0
