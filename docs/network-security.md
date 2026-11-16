# Network security monitoring

## Segmentation

| VLAN | Purpose | Policy |
|---|---|---|
| Management | Hypervisor, switches, iDRAC, admin laptops | Can reach everything |
| Servers | All VMs and containers | Reachable only on published service ports |
| Wi-Fi | Household devices | Internet, plus selected services through the reverse proxy |
| IoT | TVs, printers, smart devices | Internet only, nothing else on the LAN |
| Cameras | NVR and cameras | No internet. Only the NVR container can pull the streams |

The MikroTik router does the routing and filtering. Remote access is over WireGuard and nothing else is forwarded. In
the Servers VLAN, the more sensitive guests (AI gateway, agent VM, workstations) also have the Proxmox firewall turned
on. It drops incoming traffic by default, and for some guests it also drops outgoing traffic to the rest of RFC 1918.

## IDS: Suricata and Zeek on a port mirror

The switch mirrors both directions of the 10 Gb trunk to the router onto a 1 Gb port. That port is cabled to a separate
NIC in the hypervisor, which is bridged (no IP, ageing 0) into the IDS VM. Suricata sends signature alerts (EVE) to the
SIEM, and Zeek sends connection and protocol metadata to Loki. Both read the same interface through their own AF_PACKET
sockets.

### Capture loss

Zeek reported 2 to 10 % TCP capture loss. I measured each hop on the way to find out where packets were lost:

| Hop | Measurement | Loss |
|---|---|---|
| Switch mirror | 24 h byte counters: trunk RX+TX compared with mirror port TX | about 0.15 % |
| Hypervisor to VM | `ip -s link` on the VM's tap interface (TX dropped) | about 0.11 % of packets |
| Guest kernel | `/proc/net/softnet_stat`, interface drops | about 0 |
| Zeek / Suricata | `stats.log` `pkts_dropped`, `capture.kernel_drops` | about 0 |

The tap queue (`txqueuelen 1000`) overflowed during bursts. I raised it to 10000 with a Proxmox hookscript
([`../monitoring/ids-vm-hookscript.sh`](../monitoring/ids-vm-hookscript.sh)), and afterwards there were no drops in
18.6 M packets. The loss that's left comes from the 1 Gb mirror port, and moving the mirror to a free 10 Gb SFP+ port
should fix it. Zeek's percentage is relative to the ACKs it sees, so at night, when there's little TCP traffic, a few
lost packets show up as several percent.

Two more details. The capture NIC has the Proxmox firewall turned off, because conntrack would drop the one-sided
mirrored flows and fill the host's table. Zeek needs `ignore_checksums = T`, because mirrored frames carry offloaded
checksums.

## SIEM: Wazuh

Wazuh agents run on the hypervisor, the containers, the VMs and the Windows and Linux machines (with Sysmon on Windows).
I wrote decoders and rules for MikroTik RouterOS syslog (firewall drops, logins, config changes), Zeek notices and Trivy
image scans. Suricata alerts come in through the agent on the IDS VM. For automation there is a read-only nginx in front
of the indexer that allows only `_search` and `_count` on the alert index (see [`mcp.md`](mcp.md)).

## Monitoring

Prometheus collects node, cAdvisor, blackbox HTTP/ICMP/DNS, RouterOS (via mktxp), UPS and backup metrics. Loki and Alloy
handle the logs. Grafana alerts on offline targets, failed checks, old backups and Wi-Fi presence. The monitoring
container also builds a weekly report and sends it out.
