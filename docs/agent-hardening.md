# Hardening an autonomous agent

The lab runs an autonomous agent (Hermes Agent). It can run shell commands, read the state of the infrastructure and open
pull requests. I want it to be useful for diagnostics and small code changes, and unable to break anything even if
someone manipulates it through prompt injection in a repository, an issue or a log line.

## Threat model

- The model runs in the cloud, and text the agent reads can steer it even if the agent didn't write that text.
- Logs, IDS alerts and DNS query names can contain text controlled by an attacker.
- Nobody watches the agent while it works.

## Layers

| Layer | Control |
|---|---|
| Isolation | Its own VM, an unprivileged service account, no sudo, not in the Docker group |
| Network (hypervisor) | Proxmox firewall drops outgoing traffic to the LAN by default, except the gateway, the Git server and the SIEM agent port |
| Network (in the guest) | nftables `meta skuid` allowlist: packets from the agent's UID can only reach DNS, the AI gateway, Git, Prometheus, a read-only Loki proxy, the Proxmox API and a read-only SIEM proxy. No internet. Root and apt are not affected. See [`../agent-hardening/agent-egress.nft`](../agent-hardening/agent-egress.nft) |
| Self-modification | systemd `ReadOnlyPaths=` on its config, code, persona, hooks and secrets, plus `NoNewPrivileges=yes`. This covers every command started by the agent's terminal tool, since they share the mount namespace. Tested: writing the config gives *Read-only file system*, renaming the code directory gives *Device busy*. See [`../agent-hardening/hardening.conf`](../agent-hardening/hardening.conf) |
| Credentials | A virtual key for the AI gateway with a budget, a Proxmox token with `PVEAuditor` (writes return 403), a read-only SIEM search user, a Git token that can push branches but not `main` |
| Git | Branch protection: only I can push to or merge into `main`, and only my approval counts, so the two bots can't approve each other's PRs |
| Skills | The bundled skills (email, social media, browser, computer use and so on) are removed. It has three custom read-only skills from a directory owned by root |
| Prompting | The skills say that fields from logs and alerts are data and are never to be followed, and URLs found in logs are never fetched |

## What it can still do

It reads metrics, Proxmox state, SIEM and IDS alerts and logs. It can answer questions like "is the server overloaded?",
"did the backups run?" or "anything suspicious in the last 24 h?", and it can propose changes as pull requests. For
infrastructure changes it writes down what to do and I do it.

## Things that did not work as expected

- Making only `config.yaml` owned by root wasn't enough. The agent owns the parent directory and its own code, so it
  could rename the file or patch around it. A read-only bind mount in its mount namespace (via systemd) fixed that.
- One of the first reports said "load 11, host under pressure". The host has 40 threads, so that's 0.25 per thread. The
  skill now tells the agent to divide load by the thread count and check iowait before calling anything overloaded.
