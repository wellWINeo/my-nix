# Cloudflare DNS

## Source model

All managed records live under `dns/zones/`: `default.nix` combines the per-zone files. Zones are authoritative: an ordinary managed A, ALIAS, CNAME, MX, or TXT record missing from a declared zone is deleted by `dns-apply`. DNSControl ignores Cloudflare-maintained SOA, apex-NS, and Mail Routing MX/DKIM records.

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
make dns:plan
make dns:apply
nix run .#dns-preview -- example.com
nix run .#dns-drift-check -- example.com
nix run .#dns-apply -- --confirm example.com
```

`make dns:plan` previews every declared zone; `make dns:apply` previews and then applies every declared zone. Omit the zone argument to operate on every declared zone. `dns-preview` is read-only. `dns-drift-check` returns non-zero when changes would be needed. `dns-apply` previews again before pushing and always uses `--no-populate`.

## Initial adoption and rollback

1. Take an offline inventory of every current Cloudflare record and stop if any intended non-provider-managed record is not A, ALIAS, CNAME, MX, or TXT.
2. Declare every intended A, ALIAS, CNAME, MX, and TXT record in the appropriate `dns/zones/<zone>.nix` file only after that gate passes.
3. Run `dns-preview` until every proposed change is intended; a pure adoption should show no correction.
4. Run `dns-apply -- --confirm` only after reviewing the output.
5. If a push fails partway through, rerun preview and apply after correcting the declaration. To roll back, revert the affected file under `dns/zones/` to a known commit and apply that revision.

## GitHub Actions

A push to `main` that changes `dns/**` runs a live preview using the repository-level `CLOUDFLARE_DNS_TOKEN`. If that succeeds, the apply job waits for `cloudflare-dns-apply` Environment approval before applying the same pushed revision. Restrict that Environment to `main` and require reviewers. Do not run a local `dns-apply` while a CI apply may be pending or running; use the CI workflow for normal production reconciliation.
