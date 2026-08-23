---
name: managing-dns
description: Use when editing, validating, previewing, checking drift, or applying declarative Cloudflare DNS records in this Nix configuration repository.
---

# Managing DNS

## Scope

The authoritative non-secret source is `dns/zones/`: edit the appropriate per-zone file and register a new zone in `dns/zones/default.nix`. Use this skill before changing a managed DNS record or invoking a DNSControl app.

## Safety rules

- A declared zone is authoritative: an ordinary A, ALIAS, CNAME, MX, or TXT record omitted from it is deleted by `dns-apply`.
- Before adding a record type other than A, ALIAS, CNAME, MX, or TXT, extend `dns/lib.nix`, `dns/tests/zones.nix`, and `dns/tests/default.nix` first.
- Keep `CLOUDFLARE_DNS_TOKEN` in an operator secret manager or, for CI, as a repository-level GitHub Actions secret. Never add it to Nix, Git, `.env`, arguments, logs, or artifacts.
- Never apply from an unreviewed preview. Do not run a local apply while a CI apply is pending or running.

## Edit records

1. Edit the appropriate `dns/zones/<zone>.nix` file using relative names (`@` for the apex). Register a new zone in `dns/zones/default.nix`.
2. Use `address` for A; absolute `target` for ALIAS and CNAME; `priority` and absolute `exchange` for MX; and `text` for TXT.
3. Use ALIAS for a proxied apex target: DNSControl rejects apex CNAME source records, while its Cloudflare provider rewrites ALIAS to Cloudflare's CNAME representation. Do not enable per-record CNAME flattening.
4. Preserve ALIAS/CNAME/MX trailing dots, A/ALIAS/CNAME `proxied` state, and `ttl = "auto"` when Cloudflare reports Auto.
5. For first adoption, inventory every existing ordinary record. Do not declare Cloudflare SOA or apex NS records.

## Validate offline

```bash
make fmt
make setup-dummy-secrets
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --print-build-logs \
  ".#checks.${system}.dns-render" \
  ".#checks.${system}.dns-config" \
  ".#checks.${system}.dns-app-safety"
make check
```

## Preview, drift, and apply

Export the token without printing it, then use exactly one of:

```bash
make dns:plan
make dns:apply
nix run .#dns-preview -- [ZONE]
nix run .#dns-drift-check -- [ZONE]
nix run .#dns-apply -- --confirm [ZONE]
```

`make dns:plan` previews every declared zone, and `make dns:apply` previews then applies every declared zone. Omit `[ZONE]` for all declared zones. Preview must contain only intended changes. Drift check returns non-zero when reconciliation is needed. Apply previews again before push; run it only after a human has reviewed that preview. Unset the token immediately afterwards:

```bash
unset CLOUDFLARE_DNS_TOKEN
```

## CI

Pull-request checks are secret-free. A `main` push that changes `dns/**` runs preview with the repository-level `CLOUDFLARE_DNS_TOKEN`; its dependent apply job uses `cloudflare-dns-apply` and waits for Environment approval. Restrict that Environment to `main`, require reviewers, and approve only when every previewed change is intended.
