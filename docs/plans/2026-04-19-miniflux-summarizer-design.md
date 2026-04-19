# Miniflux Summarizer — Design

**Goal:** Deploy miniflux-summarizer on mokosh server as scheduled systemd services with secret injection via LoadCredential + jq.

## Architecture

Miniflux-summarizer is a Python CLI that fetches RSS entries from Miniflux, summarizes them via an LLM, and imports the digest back into Miniflux. It runs as a one-shot CLI invoked by systemd timers.

The NixOS module builds a JSON config template at eval time (prompts injected from .md files, API keys set to "PLACEHOLDER"). At runtime, systemd LoadCredential provides the secret files, and jq injects them into the config before exec-ing the CLI.

This follows the same pattern as the xray role (`roles/network/xray/default.nix`).

## Directory Structure

```
roles/reading/
├── calibre.nix                              ← unchanged
├── rss.nix                                  ← DELETED
├── rss/
│   ├── default.nix                          ← coordinator: imports miniflux.nix + service.nix
│   ├── miniflux.nix                         ← current rss.nix content (unchanged logic)
│   └── summarizer/
│       ├── prompts/
│       │   ├── daily.md                     ← daily digest prompt
│       │   ├── weekly.md                    ← weekly newsletter prompt
│       │   └── monthly.md                   ← monthly newsletter prompt (new)
│       └── service.nix                      ← NixOS module: config template + 4 services + 4 timers
```

## Module Option Tree

```
roles.rss
├── enable
├── baseDomain
├── summarizer
│   ├── enable
│   ├── llmApiKeyFile           (str: path to LLM API key file)
│   ├── minifluxApiKeyFile      (str: path to Miniflux API key file)
│   ├── dailyTargetFeedId       (int)
│   ├── weeklySourceFeedId      (int, default = dailyTargetFeedId)
│   ├── weeklyTargetFeedId      (int)
│   ├── monthlySourceFeedId     (int, default = weeklyTargetFeedId)
│   └── monthlyTargetFeedId     (int)
```

## Flake Input

```nix
miniflux-summarizer.url = "github:wellWINeo/miniflux-summarizer";
```

Package injected via per-machine overlay in mokosh config (same pattern as veles uses for `telemt`).

## Config Template

Built at Nix eval time:

- **Prompts**: read from `./prompts/<name>.md` via `builtins.readFile`
- **API keys**: set to `"PLACEHOLDER"`, injected at runtime
- **LLM config**: hardcoded (`x-ai/grok-4.1-fast`, `https://openrouter.ai/api/v1`)
- **Ignore rules**: hardcoded from config.example.json (subject "Sponsored", feed_id 6, category_id 3/4)
- **Feed IDs**: module options

## Systemd Services

4 services, each following the xray LoadCredential + jq pattern:

| Service | Timer (UTC) | MSK | Agent | Preset | --from |
|---------|-------------|-----|-------|--------|--------|
| miniflux-summarizer-morning | `*-*-* 06:00` | 09:00 | tech-daily | daily-morning | -12h |
| miniflux-summarizer-evening | `*-*-* 18:00` | 21:00 | tech-daily | daily-evening | -12h |
| miniflux-summarizer-weekly | `Sun *-*-* 06:00` | Sun 09:00 | tech-weekly | weekly | -7d |
| miniflux-summarizer-monthly | `*-01 06:00` | 1st 09:00 | tech-monthly | monthly | -30d |

Each service:
1. Loads secrets via `LoadCredential`
2. Injects them into the config template via `jq`
3. Writes merged config to `/tmp/` (PrivateTmp)
4. `exec miniflux-summarizer --config /tmp/summarizer-config.json --agent <name> --preset <name>`

## Agents

| Agent | Source | Source Feed | Target Feed | Presets |
|-------|--------|-------------|-------------|---------|
| tech-daily | raw_entries | — | dailyTargetFeedId | daily-morning (-12h), daily-evening (-12h) |
| tech-weekly | digests | weeklySourceFeedId | weeklyTargetFeedId | weekly (-7d) |
| tech-monthly | digests | monthlySourceFeedId | monthlyTargetFeedId | monthly (-30d) |

## Secrets

Two new secret files in `secrets/unlocked/spec.txt`:

```
mokosh:miniflux-llm-api-key:0400:root:root
mokosh:miniflux-api-key:0400:root:root
```

## Mokosh Config

```nix
# Import change
../../roles/reading/rss    # was: ../../roles/reading/rss.nix

# Config
roles.rss = {
  enable = true;
  baseDomain = domainName;
  summarizer = {
    enable = true;
    llmApiKeyFile = "/etc/nixos/secrets/miniflux-llm-api-key";
    minifluxApiKeyFile = "/etc/nixos/secrets/miniflux-api-key";
    dailyTargetFeedId = 57;
    weeklySourceFeedId = 57;
    weeklyTargetFeedId = 58;
    monthlySourceFeedId = 58;
    monthlyTargetFeedId = 59;
  };
};
```

## Files Changed Summary

| File | Action |
|------|--------|
| `roles/reading/rss.nix` | DELETE |
| `roles/reading/rss/default.nix` | CREATE |
| `roles/reading/rss/miniflux.nix` | CREATE (moved from rss.nix) |
| `roles/reading/rss/summarizer/service.nix` | CREATE |
| `roles/reading/rss/summarizer/prompts/daily.md` | CREATE |
| `roles/reading/rss/summarizer/prompts/weekly.md` | CREATE |
| `roles/reading/rss/summarizer/prompts/monthly.md` | CREATE |
| `flake.nix` | MODIFY (add input) |
| `machines/mokosh/default.nix` | MODIFY (import + options + overlay) |
| `secrets/unlocked/spec.txt` | MODIFY (add 2 entries) |
