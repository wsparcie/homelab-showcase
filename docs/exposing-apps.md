# Publishing apps without opening a port

Until recently the only thing forwarded from the internet to my router was the VPN port. That was fine for my own
use, but I also run a few side projects I want to show to other people, and they are real apps with real logins, not
demos. I wanted them reachable by name from anywhere without forwarding a port, and without making the rest of the
lab easier to reach if one of those apps is ever compromised.

The answer was an outbound-only tunnel in its own container, a firewall that treats that container as hostile, and
a short checklist an app has to pass before it goes through the tunnel.

## The connector gets its own container

A Cloudflare Tunnel connector (`cloudflared`) opens outbound connections to the provider's edge, and the edge sends
requests for my hostnames back down those connections. Nothing listens on the router.

My first attempt was a Docker container on the big host, next to the reverse proxy. I moved it for the same reason I
moved the vault out of that host: one process that is reachable from the internet should not sit beside sixty other
services. It now runs in a small unprivileged LXC:

- Debian, 256 MB of RAM, one core, the package from the vendor's apt repository (updates with `apt upgrade`).
- A systemd unit that runs as its own user with `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`,
  `PrivateDevices`, an empty capability set and no address families other than IP and Unix sockets
  ([`exposing-apps/cloudflared.service`](../exposing-apps/cloudflared.service)).
- The tunnel token lives in an `EnvironmentFile` that only root and the service group can read, and it was moved
  there from the old container without being printed anywhere.

## A firewall that assumes the connector is compromised

The container's firewall is enforced by the hypervisor, outside the guest
([`exposing-apps/tunnel-lxc.fw`](../exposing-apps/tunnel-lxc.fw)). Inbound is dropped except SSH from the
management network. Outbound is dropped except:

- DNS to the internal resolver;
- the SIEM agent port;
- one rule per published app: the app host and **that app's port only**;
- the internet.

Every other private range is dropped after those rules. Checked from inside the container: the published app answers,
while the NAS, the hypervisor's web UI and the other apps' ports time out. If someone takes over the connector, what
they can reach is exactly the list of things I already chose to publish.

The app host has a matching rule from the other side ([`exposing-apps/app-ports-firewall.sh`](../exposing-apps/app-ports-firewall.sh)):
each published port accepts only the reverse proxy and the tunnel container, and only traffic that *enters* through
the host's own interface. The first version had no interface match and also dropped container-to-container traffic on
the Docker bridges, which cut one app's backend off from its frontend for two weeks while the front page kept returning 200.

## Only the admin paths sit behind a login at the edge

Each app has public pages and a few admin or operations paths. The provider's access layer (Cloudflare Access) protects
only the admin paths, with one rule that allows my e-mail and a one-time PIN:

- `/admin*`
- `/api/admin*`
- `/api/scraper*`

An unauthenticated request to any of these gets a 302 to the login page before it reaches my network. The app still
checks roles on those routes. Two doors instead of one, and the first one is not my code.

Gotcha: the admin UI makes API calls from the browser. They only work after you have first opened a protected page and
got the access cookie, otherwise the API call is answered with a redirect instead of JSON.

## The visitor's real address, all the way down

Behind a reverse proxy and a CDN, the TCP peer is never the visitor, so a per-IP rate limit counts the proxy. Every
visitor shared one bucket until I fixed the chain:

1. The CDN adds `CF-Connecting-IP`.
2. The frontend's nginx takes the client address from that header, but only when the request comes from a private
   address ([`exposing-apps/nginx-real-ip.conf`](../exposing-apps/nginx-real-ip.conf)).
3. It then **overwrites** `X-Forwarded-For` with the address it computed, instead of appending to what the client sent.
4. The backend trusts exactly one hop (`trust proxy 1`), so a client can't spoof its address by sending its own header.

## What an app has to pass first

An app doesn't get a hostname until it passes these. The list came from a real external test of the first app, which
found nothing critical or high and six smaller things:

| Check | Why |
|---|---|
| Sessions are signed and expire | One app issued `token_<email>_<time>` and validated it by parsing the string. Anyone could forge a token for any e-mail. |
| Every route needs a login unless it is listed as public | Several controllers had no guard at all. |
| Ownership is checked, not only identity | A logged-in user must not read or change another user's records. One negative test per controller. |
| Login failures look identical | The first app answered 404 with the e-mail in the body for an unknown user and 401 for a wrong password, which is an account lookup. |
| Registration confirms the mailbox | Without it anyone can create an account for someone else's address. |
| Rate limits on login, registration and reset, keyed on the real address | See above. |
| Input validation with a whitelist, ids parsed as numbers | A malformed id returned a 500 instead of a 400. |
| The app collects only what it needs | One app stored name, surname, phone and home city that nothing used. They are gone: an account is an e-mail and a nick. |
| Account deletion | A privacy policy promises it, so it has to work. |
| Backups with a tested restore, a privacy policy, an outside probe | Real users, real data. |

## Things that went wrong, in case they save you an evening

- **CORS read from a different variable.** The deploy file set `ALLOWED_ORIGINS`; the code read `CORS_ORIGIN`. Login
  failed with a 500 on the new hostname until I grepped the code for what it really reads instead of trusting the
  config file.
- **OAuth `state` in a short-lived cookie.** The state is stored server-side and tied to the browser with a ten-minute
  cookie. Take longer than that on the provider's consent page and the callback answers 401.
- **The redirect URI has to match to the character.** The provider returned `Invalid OAuth2 redirect_uri` because I had
  registered `/auth/...` and the app sent `/api/auth/...`.
- **Verification e-mails need a real mail relay.** Two apps required a verified address to log in, and neither had a
  mail server configured, so nobody (including me) could log in. The first account had been created before the
  verification step existed and had to be marked verified by hand.
- **Soft 404s hide missing files.** A single-page app answers 200 with the same page for any path, so
  `/.well-known/security.txt` looked present to a scanner. Return a real 404 for paths with a file extension.
- **A "connection reset" in one browser** while the site worked from everywhere else was the client side (a VPN exit
  and Encrypted Client Hello), not the tunnel.
- **Pruning does not free ZFS space while snapshots hold it.** After a day of deploys the pool sat at 80%. Removing the
  build cache and old images inside the container freed nothing at the pool level until the daily snapshots that still
  referenced those blocks were gone. See [`operations.md`](operations.md#disk-space-and-snapshots).

## Still open

- A Wazuh agent on the tunnel container, and the frontend's access log in the SIEM with rules for login bursts and
  scanning. The firewall already allows the agent port.
- A cheap outside probe that checks each published hostname from the internet, not through the LAN.
- The DMARC policy moved from `p=none` to `p=quarantine`; `reject` comes after a couple of clean weeks.
