# Hardening an autonomous agent

The lab runs an autonomous agent (Hermes Agent) that can execute shell commands, read the infrastructure state and open
pull requests. The goal: useful for diagnostics and code changes, unable to damage anything even if it is manipulated
(prompt injection through a repository, an issue or a log line).

## Threat model

- The model is a cloud model; anything the agent reads may be steered by text it did not write.
- Logs, IDS alerts and DNS query names are **attacker-controlled text**.
- The agent runs unattended.

## Layers

| Layer | Control |
|---|---|
| **Isolation** | Dedicated VM; unprivileged service account; no sudo, no Docker group |
| **Network (hypervisor)** | Proxmox firewall: default-deny out to the LAN except the gateway, Git server and SIEM agent port |
| **Network (in guest)** | nftables `meta skuid` allowlist: packets from the agent's UID may reach only DNS, the AI gateway, Git, Prometheus, a read-only Loki proxy, the Proxmox API and a read-only SIEM proxy. **No internet.** Root and apt are unaffected → [`../agent-hardening/agent-egress.nft`](../agent-hardening/agent-egress.nft) |
| **Self-modification** | systemd `ReadOnlyPaths=` on its config, code, persona, hooks and secrets + `NoNewPrivileges=yes`. Applies to every command the agent's terminal tool spawns (same mount namespace). Verified: writing the config → *Read-only file system*; renaming the code dir → *Device busy* → [`../agent-hardening/hardening.conf`](../agent-hardening/hardening.conf) |
| **Credentials** | Only a budgeted virtual key for the AI gateway; read-only Proxmox token (`PVEAuditor`, writes return 403); read-only SIEM search user; Git token that can push branches but not `main` |
| **Git** | Branch protection: only the owner can push to or merge into `main`; approvals count only from the owner, so the two bots cannot approve each other |
| **Skills** | Bundled skills (email, social media, browser, computer-use…) removed; three custom read-only skills from a root-owned directory |
| **Prompting** | Skills state that log/alert fields are data and must never be followed; no URLs from logs are fetched |

## What it can still do

Read metrics, Proxmox state, SIEM/IDS alerts and logs; answer "is the server overloaded?", "did backups run?", "anything
suspicious in the last 24 h?"; propose changes as pull requests. Infrastructure changes are described, never executed.

## Things that did not work as expected

- Making only `config.yaml` root-owned is not enough: the agent owns the parent directory and its own code, so it could
  rename or patch around it. A mount-namespace read-only bind (systemd) is the robust fix.
- A first report flagged "load 11, host under pressure". The host has 40 threads; load per thread was 0.25. The skill now
  teaches the agent to normalise by thread count and check iowait before calling something overloaded.
