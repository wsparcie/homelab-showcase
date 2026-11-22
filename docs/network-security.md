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

### Keeping the alerts worth reading

Every Suricata alert arrived at the same low severity: visible on the dashboard, never pushed to chat. That sounds safe
until you realise a real scan would have looked exactly like the constant background noise, and I'd only have seen it if
I happened to be looking. So I re-scored them in the SIEM. A high-severity signature, or more than twenty alerts from
one source in two minutes (a scan or a brute-force, even when each alert on its own is dull), now reaches chat. Medium
stays on the dashboard but ranks above the noise. Known-benign signatures, like a game server's download client
announcing itself, are pinned back down by an exception so they don't cry wolf. I also disabled the stream-event rules
in the sensor itself: they were more than half of all alerts, never actionable, and an artefact of a mirror that
carries offloaded checksums. A test run with a scanner's user agent fired both the high-severity rule and the burst
rule, and nothing else did.

### A tunnel on its own interface, and a way back in

The site-to-site link to the second building had quietly been added as an extra peer on the interface that the phones'
mesh VPN manages. It worked, but it shared the phones' firewall treatment and could have been torn down by a firmware
update that rebuilt that interface. I moved it onto its own WireGuard interface with its own subnet and its own rules,
and removed the leftover peer and a duplicate route. The risk in a change like that is obvious: the far router is
reachable only over the tunnel I'm rebuilding, so one wrong key locks me out of the building. Before touching it I
opened an out-of-band path, SSH to that router over the independent mesh VPN, bound to the mesh interface only. The
router's own failover script already swings traffic to the mesh when the tunnel is down, so the fallback was a few
commands rather than a drive. The switch itself ran from a script that verifies the handshake and rolls back on its own
if it doesn't come up.

## Monitoring

Prometheus collects node, cAdvisor, blackbox HTTP/ICMP/DNS, RouterOS (via mktxp), UPS and backup metrics. Loki and Alloy
handle the logs. Grafana alerts on offline targets, failed checks, old backups and Wi-Fi presence. The monitoring
container also builds a weekly report and sends it out.
