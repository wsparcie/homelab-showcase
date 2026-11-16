# Network security monitoring

## Segmentation

| VLAN | Purpose | Policy |
|---|---|---|
| Management | Hypervisor, switches, iDRAC, admin laptops | Can reach everything |
| Servers | All VMs and containers | Reachable only on published service ports |
| Wi-Fi | Household devices | Internet + selected services via reverse proxy |
| IoT | TVs, printers, smart devices | Internet only, no lateral movement |
| Cameras | NVR + cameras | No internet; only the NVR container may pull streams |

Routing and filtering happen on the MikroTik router. Remote access is WireGuard; nothing else is forwarded. Inside the
Servers VLAN, sensitive guests (AI gateway, agent VM, workstations) additionally run the Proxmox firewall with
default-deny inbound and, where it matters, default-deny to the rest of RFC 1918.

## IDS: Suricata + Zeek on a port mirror

The switch mirrors both directions of the 10 Gb router trunk to a 1 Gb port, cabled to a dedicated NIC on the
hypervisor, bridged (no IP, ageing 0) into the IDS VM. Suricata (signatures, EVE alerts → SIEM) and Zeek (connection
and protocol metadata → Loki) read the same interface via separate AF_PACKET sockets.

### Capture-loss investigation

Zeek reported 2–10 % TCP capture loss. Instead of guessing, each hop was measured:

| Hop | Measurement | Loss |
|---|---|---|
| Switch mirror | 24 h byte counters: trunk RX+TX vs mirror-port TX | ~0.15 % |
| Hypervisor → VM | `ip -s link` on the VM's tap interface (TX dropped) | ~0.11 % of packets |
| Guest kernel | `/proc/net/softnet_stat`, interface drops | ~0 |
| Zeek / Suricata | `stats.log` `pkts_dropped`, `capture.kernel_drops` | ~0 |

Root cause: the tap queue (`txqueuelen 1000`) overflowed on bursts. Raised to 10000 with a Proxmox hookscript
([`../monitoring/ids-vm-hookscript.sh`](../monitoring/ids-vm-hookscript.sh)) → zero drops on 18.6 M packets afterwards.
The remainder is the 1 Gb mirror port; the fix is moving the mirror to a spare 10 Gb SFP+ port. Note that Zeek's
percentage is relative to ACKs seen: at night, with little TCP traffic, a few lost packets read as several percent.

Gotchas: the capture NIC has **no** Proxmox firewall (conntrack would drop one-sided mirrored flows and fill the
host's table), and Zeek needs `ignore_checksums = T` because mirrored frames carry offloaded checksums.

## SIEM: Wazuh

Agents on the hypervisor, containers, VMs and Windows/Linux endpoints (Sysmon on Windows). Custom decoders and rules for
MikroTik RouterOS syslog (firewall drops, logins, configuration changes), Zeek notices and Trivy image scans. Suricata
alerts arrive through the IDS VM's agent. A read-only nginx in front of the indexer exposes only `_search`/`_count` on
the alert index to automation (see [`mcp.md`](mcp.md)).

## Monitoring

Prometheus (node, cAdvisor, blackbox HTTP/ICMP/DNS, RouterOS via mktxp, UPS, backups), Loki + Alloy for logs, Grafana
alerting for offline targets, failed checks, stale backups and Wi-Fi presence. A weekly report is rendered and sent
from the monitoring container.
