# DNS Management Follow-up Design

> **Historical design record:** For the implemented source layout and CI workflow, use [`docs/dns.md`](../../dns.md) and `.agents/skills/managing-dns/SKILL.md`.

## Scope

Complete the declarative adoption of `uspenskiy.tech` and `uspenskiy.su`, resolve the DNS review findings, and add a repository-local `managing-dns` operational skill.

## Zone adoption

`dns/zones.nix` will declare every ordinary A, ALIAS, CNAME, MX, and TXT record in the reviewed Cloudflare exports dated 2026-08-22. Cloudflare-maintained SOA and apex NS records stay omitted. All exported TTL values of `1` are represented as `ttl = "auto"`; numeric TTL values remain numeric. Names are relative to their zone, ALIAS/CNAME and MX targets retain their trailing dots, and A/ALIAS/CNAME proxy state is copied from the export.

The proxied `uspenskiy.tech` apex target `website-63n.pages.dev.` is source type `ALIAS`. DNSControl rejects apex CNAME source records by design, but its Cloudflare provider supports ALIAS and rewrites it to Cloudflare's CNAME representation. ALIAS therefore has CNAME's absolute-target and proxied semantics in this source model. Per-record CNAME flattening remains disabled.

The multi-string BIND representation of the RSA DKIM TXT record is concatenated without an inserted separator, preserving its DNS character-string value.

## Review fixes

- `dns/apps.nix` uses `jq -n` to create the temporary credentials JSON and uses the repository's camelCase convention for its domain argument array.
- Renderer fixture assertions verify TTLs plus CNAME and ALIAS target/proxy output in addition to the existing record shape checks.
- A separate flake check executes each generated app without `CLOUDFLARE_DNS_TOKEN`, requires the exact safe failure message, and statically confirms generated wrappers include fixed `--no-populate`, `--ir`, and `--creds` arguments.
- `docs/dns.md` warns operators to coordinate emergency local applies with CI applies.

## Skill deployment

Create `.agents/skills/managing-dns/SKILL.md` as the DNS operator reference. It covers safe source edits, offline validation, zero-surprise preview, drift checks, reviewed apply, token handling, authoritative deletion, and the required live-inventory gate for unsupported record types.

Create `.claude/skills` as the relative symlink `../.agents/skills`, and add a concise `AGENTS.md` reference directing agents to `managing-dns` for declarative Cloudflare DNS changes.

## Validation

Before implementation, exercise a baseline agent scenario without the new skill. After writing it, repeat the scenario to ensure the skill directs an operator through validation and preview before apply.

After code changes, run the DNS-specific flake checks, generated-app safety check, formatting, YAML parsing, `make check`, and a token-authenticated live preview separately when an operator has supplied the token. No live push is part of this change.
