# AI gateway (LiteLLM)

Every AI client in the lab — the chat UI used by the family, the browser IDE, Coder workspaces, a coding loop and an
autonomous agent — talks to **one** OpenAI-compatible endpoint. Provider keys exist in exactly one place.

## Why

- **Keys stay put.** Raw provider keys live only in the gateway container's `.env` (mode 600). Clients get *virtual keys*
  that can be revoked, budgeted and scoped without touching the provider account. Before this, a raw key sat on the
  agent VM where the agent itself could read it.
- **Budgets per client.** Each virtual key has a hard monthly budget (e.g. $5 / 30 days for agents). Over budget, the
  gateway refuses requests instead of the provider sending an invoice.
- **Stable names.** Clients use aliases (`deepseek-pro`, `claude-sonnet`, `local-qwen`); swapping the underlying model is
  a one-line gateway change.

## Models

| Alias family | Backend | Notes |
|---|---|---|
| `deepseek-*`, `claude-*` | Cloud APIs | Paid; explicit prices in `model_info` so spend tracking is exact |
| `local-*` | Ollama on a CPU-only VM | Private, free, slow; the only choice for private data |
| `free-*` | Gemini, Groq, OpenRouter `:free`, NVIDIA NIM | Free tiers may train on prompts → never on agent keys |
| `free-auto` | Fallback chain | Groq first; on 429/5xx/timeout → Gemini Flash-Lite → NIM → OpenRouter |
| `smart-auto` | Complexity router | See below |

Free providers were verified live, not from memory: several "free tiers" from mid-2025 guides were gone by late 2026
(card-required trials, retired APIs), so the gateway only includes what answered a test request.

## Routing

**Fallback chains** handle the reality of free tiers: rate limits and overloaded models. A flaky model gets a short
timeout and `num_retries: 0`, so the fallback kicks in after seconds instead of minutes.

**`smart-auto`** uses LiteLLM's complexity router in `heuristic_first` mode: a local rule-based scorer settles obvious
SIMPLE prompts in under a millisecond; everything else is classified by a small, fast model. Tiers map to free models,
with only the REASONING tier going to a paid model.

Lesson learned: the rule-based scorer alone rated *"think step by step: prove that …"* as MEDIUM (score 0.19); keyword
heuristics confuse "long" with "hard". The LLM classifier fixed it.

## Access control

| Key | Models | MCP tools |
|---|---|---|
| family chat | local + free + paid + routers | none |
| IDE | all incl. Claude | read-only infra tools |
| agent | paid only (no free tiers: they may train on prompts) | read-only infra tools |
| coding loop | paid only | none |

Gotcha worth knowing: in LiteLLM a key **without** an MCP setting sees *all* MCP servers —
`require_key_mcp_access_defined` only stops inheritance from teams. Every key therefore gets an explicit
`object_permission.mcp_servers`, including `["no-mcp-servers"]`.

## Network

The gateway container accepts TCP 4000 only from the hosts that need it and may reach only DNS, the SIEM, the Ollama VM,
the MCP proxy and the internet; the rest of RFC 1918 is dropped. The admin UI is behind the reverse proxy, reachable
only on LAN/VPN, with personal accounts (the master-key login is disabled).

Config example: [`../ai-gateway/config.example.yaml`](../ai-gateway/config.example.yaml).
