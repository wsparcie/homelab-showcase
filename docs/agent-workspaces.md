# Workspaces where a coding agent runs the whole app

Coding agents in the lab work in Coder workspaces: one Docker container per app, created from a Terraform template.
At first a workspace held the code and an editor, so the agent could write changes but never see them run. Now it can
bring the app up from nothing, check each component, click through the running frontend and open a pull request
with a report. It still can't deploy, reach the home network or merge anything.

## What a workspace has

| Part | Details |
|---|---|
| Agent | opencode (and aider) using models through the LLM gateway, with a per-client key and a monthly budget. No provider key lives in Coder. |
| Dev services | Its own Postgres 17 (TimescaleDB image), Redis 7 and **Mailpit**, a fake SMTP server that keeps every message and shows it in a web UI. They run on an internal Docker network with no internet and no published ports. See [`../agent-workspaces/devservices.tf`](../agent-workspaces/devservices.tf) |
| Environment | `DATABASE_URL`, `REDIS_URL`, `SMTP_HOST`… point at those services and take precedence over the repo's `.env`. |
| Browser | Playwright MCP with headless Chromium, so the agent can open pages, fill in forms, and read the console and failed requests. |
| Web search | An MCP tool backed by a self-hosted SearXNG instance: no API key, no account. |
| Rules | [`../agent-workspaces/AGENTS.md`](../agent-workspaces/AGENTS.md), written into the agent's global rules on every start: the bring-up checklist, how to verify, side effects off, how to commit and open PRs, and what web content is allowed to do (nothing). |
| Limits | 6 GiB RAM and a lower CPU weight for the workspace; Postgres 1 GiB, Redis 256 MiB, Mailpit 128 MiB. |

## Isolation

- **Network.** Workspaces sit on their own Docker bridge. A `DOCKER-USER` chain lets them reach the internet, the
  reverse proxy (Coder and the Git server), the LLM gateway and the search engine. Every private range is dropped,
  and so is traffic between workspaces. Traffic from the bridge to the host's own ports is dropped in `INPUT`.
  See [`../agent-workspaces/workspace-egress.sh`](../agent-workspaces/workspace-egress.sh). The rules match on
  `conntrack --ctorigdst`, the address the container asked for, because Docker's DNAT has already rewritten the
  destination by the time the packet reaches `DOCKER-USER`.
- **No Docker socket, no infrastructure credentials.** Dockerfiles and compose files are not run in the workspace;
  the dev services above replace them.
- **Git.** The agent clones and pushes as a bot account that has write access only to the app repositories. `main` is
  protected everywhere, and only my approval counts.
- **Secrets.** Global git hooks run gitleaks on every commit and every push. They also chain the repo's own hooks, which a
  global `core.hooksPath` would otherwise skip. See [`../agent-workspaces/git-hook.sh`](../agent-workspaces/git-hook.sh).
  The PR helper scans the whole branch again before pushing. Repos that use husky set their own `hooksPath` and
  bypass the global hooks, so that scan is the backstop. See [`../agent-workspaces/pr-helper.sh`](../agent-workspaces/pr-helper.sh).

## Pull requests and CI

The agent works on an `agent/<topic>` branch and commits after each step that builds. When the task is done, it writes
a report of what changed and how it was checked: commands, test results, pages opened in the browser, and what still
fails. Then `pr-helper "title" report.md` pushes the branch and opens or updates the PR.

Every PR runs Gitea Actions on a separate small VM. CI runs code from pull requests, so the runner VM's firewall
allows DNS, the Git server and the internet for packages, and nothing else on the LAN. See
[`../agent-workspaces/ci/runner.fw`](../agent-workspaces/ci/runner.fw). Jobs run in throwaway containers that have a
memory and PID cap, no host volumes and no Docker socket
([`../agent-workspaces/ci/runner-config.yaml`](../agent-workspaces/ci/runner-config.yaml)). The workflow is
generated per repo: gitleaks on the new commits, then install, Prisma migrations against a throwaway Postgres,
typecheck, unit tests and build. Lint and e2e are reported but not blocking yet
([`../agent-workspaces/ci/workflow.yml`](../agent-workspaces/ci/workflow.yml)).

The first round found real problems straight away. One repo's lockfile had drifted out of sync on `main`, one had a
type error nobody had noticed, and one test suite hung for 25 minutes waiting for open handles. Every job now has a
timeout, and e2e runs with `--forceExit`.

## The first end-to-end run

I asked the agent to bring up a backend and frontend pair from scratch and test it. It passed 21 of 23 checks and
found genuine bugs: a registration form that silently dropped three fields, and an auth guard that returned 500
instead of 401.

It also sent 42 real Discord messages. The seed script had real webhook URLs hardcoded, and the workspace's `.env`
held real keys left over from earlier manual work. The backend logged in a real bot and started a scraper against a
real website. The network rules worked as designed. The dangerous part was already inside the box, and the internet
has to be open for package installs. The rules changed:

- Read the seed for real URLs (webhooks, e-mail addresses, API endpoints) before running it.
- Keep scrapers, mail, chat integrations, paid APIs and real OAuth off. If something starts on its own and can't be
  switched off, stop and report it instead of letting it run.
- To switch a variable off, export it **empty**. `unset` does nothing here, because dotenv and Prisma fill unset
  variables back in from `.env`.
- Flags documented in `.env.example` were not always wired in the code, so grep the source before relying on one.

## Things that did not work as expected

- **A config file is a wish until something loads it.** The first per-workspace database network was created without
  an explicit subnet. Docker picked a range that a LAN behind the VPN also uses, and for a few minutes the Docker
  host routed that site's traffic into a container network. I had configured `default-address-pools` weeks earlier,
  but the daemon had never been restarted, so it had never read them. Now every network in the template states its
  own subnet.
- **npm 11 blocks install scripts.** `esbuild`, `prisma`, `bcrypt` and friends need `allow-scripts` in `.npmrc`. The
  equivalent environment variable is ignored for project installs. The workspace and CI use the same list.
- **Gitea ignores `.github/workflows` once `.gitea/workflows` exists** on a branch. That makes it easy to migrate repos
  that still carry GitHub workflows.
- **Headless agent runs auto-reject "ask" permissions.** The sibling repo sits outside the working directory, so
  reading it needed an explicit allow.
- **`npm run | grep -q` fails under `pipefail`.** grep exits on the first match and npm dies of SIGPIPE. CI reads
  `package.json` with `node -p` instead.
