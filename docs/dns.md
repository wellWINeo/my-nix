# Cloudflare DNS

## Source model

All managed records live in `dns/zones.nix`. Zones are authoritative: an ordinary managed A, ALIAS, CNAME, MX, or TXT record missing from a declared zone is deleted by `dns-apply`. DNSControl ignores Cloudflare-maintained SOA, apex-NS, and Mail Routing MX/DKIM records.

Use `ALIAS`, not `CNAME`, for a proxied apex target. DNSControl rejects apex CNAME source records by design; its Cloudflare provider rewrites ALIAS to Cloudflare's apex CNAME representation. ALIAS has the same absolute `target` and `proxied` semantics as CNAME. Do not enable per-record CNAME flattening.

## Cloudflare token

Create one token scoped only to the managed zones with `Zone / Zone / Read` and `Zone / DNS / Edit`. Make `CLOUDFLARE_DNS_TOKEN` available only through the operator's secret manager, then run:

```bash
# With CLOUDFLARE_DNS_TOKEN already exported without echoing it:
nix run .#dns-preview -- example.com
unset CLOUDFLARE_DNS_TOKEN
```

The wrapper creates a mode-`0600` temporary `creds.json` file and removes it on exit. Never place the token in Nix, Git, a `.env` file, or shell history.

## Commands

```bash
nix run .#dns-preview -- example.com
nix run .#dns-drift-check -- example.com
nix run .#dns-apply -- --confirm example.com
```

Omit the zone argument to operate on every declared zone. `dns-preview` is read-only. `dns-drift-check` returns non-zero when changes would be needed. `dns-apply` previews again before pushing and always uses `--no-populate`.

## Initial adoption and rollback

1. Take an offline inventory of every current Cloudflare record and stop if any intended non-provider-managed record is not A, ALIAS, CNAME, MX, or TXT.
2. Declare every intended A, ALIAS, CNAME, MX, and TXT record in `dns/zones.nix` only after that gate passes.
3. Run `dns-preview` until every proposed change is intended; a pure adoption should show no correction.
4. Run `dns-apply -- --confirm` only after reviewing the output.
5. If a push fails partway through, rerun preview and apply after correcting the declaration. To roll back, revert `dns/zones.nix` to a known commit and apply that revision.

## GitHub Actions

The workflow uses the same `CLOUDFLARE_DNS_TOKEN` in the `cloudflare-dns-drift` and `cloudflare-dns-apply` environments. Restrict both environments to `main`; require reviewers only for `cloudflare-dns-apply`. Scheduled jobs fail on drift. Manual dispatch first publishes a live preview, then an `apply: true` run waits for Environment approval before applying the requested main-branch commit. Do not run a local `dns-apply` while a CI apply may be pending or running; use the CI workflow for normal production reconciliation.
