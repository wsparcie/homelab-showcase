#!/bin/sh
# On the app host (a Docker host): every published app port accepts only the reverse proxy and the tunnel
# container. Placeholder addresses. Only traffic that ENTERS through eth0 is filtered: container-to-container traffic
# on the Docker bridges (a frontend's nginx calling backend:3000) must not be dropped. Without "-i eth0" these rules
# once broke exactly that traffic.
set -eu
PROXY=10.10.20.11
TUNNEL=10.10.20.16
for port in 3000 3010 3020 3030; do
  drop="-i eth0 -p tcp -m conntrack --ctorigdstport $port --ctdir ORIGINAL ! -s $PROXY -j DROP"
  iptables -C DOCKER-USER $drop 2>/dev/null || iptables -I DOCKER-USER 1 $drop
  # inserted after the DROP so it ends up above it
  allow="-i eth0 -s $TUNNEL -p tcp -m conntrack --ctorigdstport $port --ctdir ORIGINAL -j RETURN"
  iptables -C DOCKER-USER $allow 2>/dev/null || iptables -I DOCKER-USER 1 $allow
  # no IPv6 path to the app ports at all
  drop6="-i eth0 -p tcp -m conntrack --ctorigdstport $port --ctdir ORIGINAL -j DROP"
  ip6tables -C DOCKER-USER $drop6 2>/dev/null || ip6tables -I DOCKER-USER 1 $drop6
done
