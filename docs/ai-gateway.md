# AI gateway (LiteLLM)

All AI clients in the lab use one OpenAI-compatible endpoint: the chat UI the family uses, the browser IDE, Coder
workspaces, a coding loop and an autonomous agent. The provider keys are stored in one place only.

## Reasons

- Provider keys stay in the gateway container's `.env` (mode 600). Clients get virtual keys, which I can revoke, budget
  and limit without touching the provider account. Before this, a raw key was on the agent VM, where the agent itself
  could read it.
- Each virtual key has a hard monthly budget, for example $5 per 30 days for the agents. When a key runs out, the gateway
  refuses requests, so there is no surprise invoice from the provider.
- Clients use aliases (`deepseek-pro`, `claude-sonnet`, `local-qwen`). Switching the model behind an alias is one line
  in the gateway config.

## Models

| Aliases | Backend | Notes |
|---|---|---|
| `deepseek-*`, `claude-*` | Cloud APIs | Paid. Prices are set in `model_info` so spend tracking matches the bill |
| `local-*` | Ollama on a VM without a GPU | Private, free and slow. The only option for private data |
| `free-*` | Gemini, Groq, OpenRouter `:free`, NVIDIA NIM | Free tiers may train on prompts, so they are never on agent keys |
| `free-auto` | Fallback chain | Groq first. On 429, 5xx or timeout it tries Gemini Flash-Lite, then NIM, then OpenRouter |
| `smart-auto` | Complexity router | Described below |

I tested every free provider with a real request. Several free tiers listed in guides from mid-2025 had disappeared by
late 2026 (trials that need a card, APIs that were shut down), so only the ones that answered are in the config.

## Routing

Free tiers hit rate limits and overloaded models often, so they sit in fallback chains. A model that fails a lot gets a
short timeout and `num_retries: 0`, and the next one in the chain takes over after a few seconds.

`smart-auto` uses LiteLLM's complexity router in `heuristic_first` mode. A local rule-based scorer handles prompts that
are clearly simple in under a millisecond, and a small fast model classifies the rest. The tiers map to free models and
only the REASONING tier goes to a paid one.

With the rule-based scorer alone, *"think step by step: prove that …"* came out as MEDIUM (score 0.19). Keyword rules
tend to treat long prompts as hard ones and miss short hard ones. Adding the LLM classifier fixed this.

## Access control

| Key | Models | MCP tools |
|---|---|---|
| family chat | local, free, paid and the routers | none |
| IDE | all, including Claude | read-only infra tools |
| agent | paid only (free tiers may train on prompts) | read-only infra tools |
| coding loop | paid only | none |

In LiteLLM a key with no MCP setting can see all MCP servers. `require_key_mcp_access_defined` only stops a key from
inheriting its team's servers. Because of that every key has `object_permission.mcp_servers` set explicitly, even if
it's just `["no-mcp-servers"]`.

## Network

The gateway container accepts TCP 4000 only from the hosts that use it. Outgoing, it can reach DNS, the SIEM, the
Ollama VM, the MCP proxy and the internet, and the rest of RFC 1918 is dropped. The admin UI sits behind the reverse
proxy, works only from the LAN or VPN, and uses personal accounts. Logging in with the master key is disabled.

Example config: [`../ai-gateway/config.example.yaml`](../ai-gateway/config.example.yaml).
