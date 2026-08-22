# Declarative Cloudflare DNS Design

## Goal

Manage the intended DNS records of existing Cloudflare zones as Nix data in this flake. Reconciliation must be authoritative per managed zone, run separately from NixOS deployment, support both a local operator workflow and a protected GitHub Actions workflow, and never place Cloudflare credentials in the Nix store.

## Decision

Use **DNSControl** with Cloudflare, with its JSON intermediate representation (IR) generated from Nix record declarations.

DNSControl is a better fit than OpenTofu/Terraform for this DNS-only requirement: it reads a zone's live records during every `preview` or `push` and, by default, removes records not declared in a normal managed domain. It therefore has native authoritative-zone semantics and needs no persistent state backend or resource imports. OpenTofu/Terraform would manage only the records in its state, require a shared locked state backend for local and CI use, and require imports for existing records.

The supporting research and primary-source links are in `docs/research/cloudflare-dns-declarative-options.summary.md`.

## Scope

Included:

- Existing Cloudflare DNS zones and DNS records only.
- A direct Nix source of truth for each zone's complete intended record set.
- Local live preview and explicit apply commands.
- GitHub Actions static validation, scheduled drift detection, and protected manual apply.
- An initial adoption procedure for manually created Cloudflare records.

Excluded:

- Cloudflare zone settings, rules, Workers, Access, Pages, or other Cloudflare resources.
- NixOS activation-time DNS changes.
- Terraform/OpenTofu state management.
- Storing, encrypting, or deploying credentials through Nix.

## Source Model and Rendering

Add a dedicated `dns/` area with three clear responsibilities:

1. `dns/zones.nix` declares zones as an attribute set keyed by zone name. Each zone contains its full desired list of records. Records use a tagged Nix schema: common fields identify the record type and owner name, while type-specific fields express its value and optional Cloudflare/DNS metadata such as TTL, proxy status, or priority.
2. `dns/render.nix` is a pure renderer and validator. It turns the declarations into DNSControl JSON IR, validates zone and record invariants, and produces deterministic output.
3. The flake exposes the generated IR and DNSControl-based applications. The generated IR is safe to place in the Nix store because it contains only public DNS configuration and no credentials.

Implementation begins by inventorying the zones, then fixes the initial schema to every record type and metadata field actually present. The source model must reject invalid type/field combinations, records outside their declared zone, and identical duplicate records. Support for a new record type is added deliberately through the tagged schema and renderer rather than as unvalidated free-form JSON.

DNSControl's normal purge behavior is retained. A record omitted from a managed zone is deleted at the next successful apply. DNSControl/Cloudflare-owned exceptions, such as provider-managed SOA, apex NS, and Mail Routing records, remain provider-managed. Any non-provider exception must be explicit in the Nix source and documented with why it is not under this repository's authority.

## Runtime Interfaces and Secret Boundary

Expose three flake apps backed by one shared wrapper:

- `dns-preview` loads the generated IR and reports the live Cloudflare diff for selected zone(s).
- `dns-drift-check` runs preview with `--expect-no-changes`, returning non-zero when live DNS differs from Git.
- `dns-apply` requires an explicit confirmation argument, performs a fresh preview, and then runs DNSControl `push`.

Every live command uses DNSControl's `--no-populate` option, so it cannot create a zone due to a typo or missing zone.

The wrapper obtains `CLOUDFLARE_DNS_TOKEN` only from its runtime environment. It creates an ephemeral DNSControl credentials input with restrictive permissions, passes it to DNSControl, and removes it on exit. It must not print the credential, enable shell tracing, pass it on a command line, embed it in a derivation, or write it to the repository.

The Cloudflare token is limited to the managed zones and has only `Zone:Read` and `DNS:Edit` permissions.

## Operations and CI

### Local workflow

An operator obtains the token from their own secret manager, exports it for the command only, runs `dns-preview`, reviews every correction, and then runs `dns-apply` with its explicit confirmation. Local applies are permitted, so team operations must avoid concurrent local and CI applies.

### GitHub Actions

- Pull requests run only secret-free Nix evaluation, schema/render tests, and generated-artifact checks. They do not receive a Cloudflare token.
- A scheduled trusted workflow runs `dns-drift-check` and reports unexpected live changes. It uses the `cloudflare-dns-drift` GitHub Environment, restricted to the default branch but without an approval gate.
- A manually dispatched apply workflow accepts a full commit SHA, verifies that it is reachable from the protected default branch, and checks out that exact revision. Its drift job runs first; the dependent apply job uses the `cloudflare-dns-apply` GitHub Environment, so required reviewers approve only after they can inspect the current drift output. The apply job serializes deployments with a GitHub Actions concurrency group and invokes `dns-apply` non-interactively with the explicit confirmation argument.

Store the same single Cloudflare token as `CLOUDFLARE_DNS_TOKEN` in both environments: GitHub Environment separation protects execution paths, while Cloudflare has only one credential to rotate. Both environments must be restricted to the default branch; only `cloudflare-dns-apply` requires reviewers.

The CI workflow must never echo commands containing credentials or upload credentials as artifacts. The protected apply environment is the canonical CI deployment path; a local operator must coordinate before an emergency local apply.

## Adoption, Failure Recovery, and Rollback

Do not remove manual Cloudflare records before adoption. First export an offline Cloudflare record inventory and backup for each managed zone. Translate all intended existing records, including TTL, proxy status, priorities, and other relevant metadata, into the Nix declaration.

Run `dns-preview --no-populate` until the proposed correction set is exactly intended—ideally empty for a pure adoption. A matching manual record needs no import or special adoption command; DNSControl sees it live and makes no change. An intended record omitted from Nix is proposed for deletion, so the first push must not occur until the complete desired set is reviewed.

If an apply fails partway through, rerun preview: live Cloudflare state remains the recovery input and the next apply converges it to the committed declaration. Roll back by reverting the record declaration to a known Git revision and applying it. Retain the pre-adoption backup until the initial reconciliation has been verified.

## Verification

The implementation must provide:

- Nix evaluation and fixture tests for valid representative records and invalid schema cases.
- Deterministic expected DNSControl IR fixtures for supported record types and metadata.
- A fixture test that decodes the rendered IR using the pinned DNSControl version, so an IR-schema incompatibility fails before a live deployment.
- A documented manual smoke test against an existing zone: initial zero-surprise preview, one reviewed test change, confirmation that preview becomes clean after apply, and a revert/apply rollback.
- CI verification that static checks need no Cloudflare token; live drift and apply checks use runtime credentials only.

For unusually large zones, stage initial reconciliation because DNSControl's Cloudflare provider documents a per-domain correction limit for a single push.

## Alternatives Rejected

- **OpenTofu/Terraform generated from Nix:** suitable for broader Cloudflare infrastructure but adds state, locking, and imports while not natively deleting untracked records in an authoritative existing zone.
- **A custom Cloudflare API reconciler:** would duplicate mature DNS diffing, type normalization, pagination, retries, deletion safety, and provider-specific exceptions.
- **NixOS `cloudflare-ddns`:** updates dynamic-address records on a schedule; it is not authoritative zone reconciliation and violates the separate-apply requirement.
