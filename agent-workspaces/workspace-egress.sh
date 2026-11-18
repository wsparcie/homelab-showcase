#!/bin/sh
# Egress policy for coding-agent workspace containers on the Docker host.
# Workspaces may reach the internet, the reverse proxy (Coder, Git server), the LLM gateway and the search engine.
# Everything else private (LAN, VPN, tailnet, other Docker networks, this host's own ports) is dropped, and
# workspaces can't reach each other. Their dev services (Postgres/Redis/Mailpit) sit on per-workspace internal
# networks, which this does not touch. Idempotent; run by a systemd unit (PartOf=docker.service) after Docker starts.
set -eu
NET=coder-workspaces
SUBNET=172.31.100.0/24      # always explicit: see the address-pool note in docs/agent-workspaces.md
BR=br-coder-ws
PROXY_IP=192.0.2.11         # reverse proxy on this host (Coder UI, git.example.lan)
SEARCH_PORT=8080            # SearXNG on the same host, LAN-bound
GATEWAY=192.0.2.71          # LiteLLM gateway

docker network inspect "$NET" >/dev/null 2>&1 ||
  docker network create --driver bridge --subnet "$SUBNET" -o com.docker.network.bridge.name="$BR" \
    --label managed-by=workspace-egress "$NET" >/dev/null

iptables -N CODER-WS 2>/dev/null || iptables -F CODER-WS
iptables -A CODER-WS -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -A CODER-WS -d "$SUBNET" -j DROP                                  # workspace-to-workspace
# ctorigdst: match the address the workspace asked for, before Docker's DNAT rewrote it
iptables -A CODER-WS -p tcp -m conntrack --ctorigdst "$PROXY_IP" --ctorigdstport 443 -j RETURN
iptables -A CODER-WS -p tcp -m conntrack --ctorigdst "$PROXY_IP" --ctorigdstport "$SEARCH_PORT" -j RETURN
iptables -A CODER-WS -p tcp -d "$GATEWAY" --dport 4000 -j RETURN
for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 192.0.2.0/24; do
  iptables -A CODER-WS -d "$n" -j DROP
done
iptables -A CODER-WS -j RETURN                                             # internet
iptables -C DOCKER-USER -s "$SUBNET" -j CODER-WS 2>/dev/null || iptables -I DOCKER-USER -s "$SUBNET" -j CODER-WS

# this host's own services (sshd, exporters, published container ports) from the workspace bridge
iptables -N CODER-WS-IN 2>/dev/null || iptables -F CODER-WS-IN
iptables -A CODER-WS-IN -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -A CODER-WS-IN -j DROP
iptables -C INPUT -i "$BR" -j CODER-WS-IN 2>/dev/null || iptables -I INPUT -i "$BR" -j CODER-WS-IN
