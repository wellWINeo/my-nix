---
name: managing-dns
description: Use when editing, validating, previewing, checking drift, or applying declarative Cloudflare DNS records in this Nix configuration repository.
---

# Managing DNS

## Scope

The authoritative non-secret source is `dns/zones.nix`. Use this skill before changing a managed DNS record or invoking a DNSControl app.

## Safety rules

- A declared zone is authoritative: an ordinary A, ALIAS, CNAME, MX, or TXT record omitted from it is deleted by `dns-apply`.
- Before adding a record type other than A, ALIAS, CNAME, MX, or TXT, extend `dns/lib.nix`, `dns/tests/zones.nix`, and `dns/tests/default.nix` first.
- Keep `CLOUDFLARE_DNS_TOKEN` in an operator secret manager or GitHub Environment only. Never add it to Nix, Git, `.env`, arguments, logs, or artifacts.
- Never apply from an unreviewed preview. Do not run a local apply while a CI apply is pending or running.

## Edit records

1. Edit `dns/zones.nix` using relative names (`@` for the apex).
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
nix run .#dns-preview -- [ZONE]
nix run .#dns-drift-check -- [ZONE]
nix run .#dns-apply -- --confirm [ZONE]
```

Omit `[ZONE]` for all declared zones. Preview must contain only intended changes. Drift check returns non-zero when reconciliation is needed. Apply previews again before push; run it only after a human has reviewed that preview. Unset the token immediately afterwards:

```bash
unset CLOUDFLARE_DNS_TOKEN
```

## CI

Pull-request checks are secret-free. Scheduled drift and manual preview use `cloudflare-dns-drift`; approved apply uses `cloudflare-dns-apply`. Dispatch manual CI from `main` with a full reachable commit SHA, inspect preview output, and approve the Environment deployment only when every change is intended.
