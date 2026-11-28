# Exposing apps through an outbound-only tunnel

Sanitised configs for [`docs/exposing-apps.md`](../docs/exposing-apps.md). Addresses are placeholders.

| File | What it is |
|---|---|
| [`cloudflared.service`](cloudflared.service) | Hardened systemd unit for the tunnel connector in its own container |
| [`tunnel-lxc.fw`](tunnel-lxc.fw) | Hypervisor firewall for that container: default drop, one rule per published port |
| [`app-ports-firewall.sh`](app-ports-firewall.sh) | App host: each published port accepts only the reverse proxy and the tunnel container |
| [`nginx-real-ip.conf`](nginx-real-ip.conf) | Visitor address from the CDN header, `X-Forwarded-For` overwritten |
