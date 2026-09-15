# Public Anytype MCP on Mokosh

**Status:** approved
**Date:** 2026-09-14

## Goal

Publish a complete Anytype MCP tool surface at
`https://anytype.uspenskiy.tech/mcp`. The endpoint will use HTTPS and one
static bearer token, while all Anytype data-plane services remain local to
`mokosh`.

The server will use a dedicated headless Anytype bot. Space membership is
intentionally an operator-managed Anytype action: the bot has access only to
spaces the operator explicitly invites it to join.

## Scope

- Add `nix-anysync` as a flake input following this repository's `nixpkgs`.
- Use the input's overlay on `mokosh` for `pkgs.anytype-cli`,
  `pkgs.anytype-heart`, and `pkgs.anytype-mcp`.
- Add an auto-imported `roles.anytype-mcp` role, enabled only on `mokosh`.
- Run a persistent headless Anytype CLI bot on loopback.
- Run the official Anytype MCP package through the Nixpkgs `mcp-proxy`
  Streamable-HTTP bridge on loopback.
- Terminate TLS and authenticate the public `/mcp` endpoint with Nginx.
- Make every upstream Anytype MCP tool available, including mutation tools.
- Persist and back up the headless CLI state using the existing encrypted
  restic backup role.
- Document manual bot creation, invitation, API-key creation, rotation, and
  recovery.

## Non-Goals

- Do not deploy the Any-Sync network services. This phase uses the ordinary
  Anytype Network; Any-Sync is not the local HTTP API used by MCP.
- Do not expose the Anytype CLI API, the MCP bridge listener, or a new public
  TCP port.
- Do not use `anytype-agent-runtime`; it executes JavaScript against an
  already-existing Anytype API and neither maintains a headless node nor
  serves MCP.
- Do not add OAuth, per-user identities, a web UI, or multi-user policy.
- Do not reduce the generated Anytype tool set or apply a local logging patch
  to the official MCP package.
- Do not add explicit Origin rejection, CORS controls, or request-rate limits
  beyond the selected upstream components' defaults.
- Do not create a new local package derivation for Anytype MCP, the CLI, or
  Heart. Package compatibility is supplied by the `nix-anysync` overlay and
  Nixpkgs.

## Package Decisions

The requested [`wellWINeo/nix-anysync`](https://github.com/wellWINeo/nix-anysync)
flake is the package source for the Anytype components:

- It defines `anytype-mcp` as a pinned `buildNpmPackage` derivation.
- Its overlay overrides the Nixpkgs `anytype-cli` and `anytype-heart`
  packages with its tested versions.
- It does not provide a NixOS service module for the CLI, MCP bridge, or
  public virtual host. Those are composition concerns for this repository.

The implementation will add this input with its `nixpkgs` input following the
repository's existing `nixpkgs`, then add `inputs.nix-anysync.overlay` to the
existing mokosh-only overlays. Evaluation must confirm that the pinned
Nixpkgs revision still provides the base CLI and Heart derivations the overlay
overrides.

Nixpkgs' `mcp-proxy` provides the remaining transport adapter: it launches a
local stdio MCP command and publishes its Streamable-HTTP endpoint. No npm,
container, or imperative installer runs on mokosh.

## Architecture

```text
Authorized MCP client
  |
  | HTTPS + Authorization: Bearer <public token>
  v
Nginx :443 -- anytype.uspenskiy.tech/mcp
  |
  | loopback Streamable HTTP
  v
mcp-proxy :8118 -- loopback only
  |
  | stdio child process
  v
official anytype-mcp
  |
  | HTTP + private Anytype API key
  v
anytype-cli :31012 -- loopback only
  |
  v
Anytype Network and the bot's explicitly joined spaces
```

The public MCP protocol is Streamable HTTP, not the legacy SSE endpoint. The
Nginx virtual host will proxy only `= /mcp` to the bridge. It will use the
existing `uspenskiy.tech` ACME certificate and the repository's normal
recommended proxy settings. The root path and every other path will return
`404`.

No new `networking.firewall.allowedTCPPorts` entry is required: the only
Internet-facing listener is the server's existing Nginx HTTPS listener.

## Role and Service Boundaries

Create `roles/anytype-mcp.nix`. Its public options are limited to `enable`
and `baseDomain`; it derives the hostname as `anytype.${baseDomain}` and owns
all service implementation details.

When enabled, the role creates two system services and a dedicated Nginx
virtual host.

### Headless Anytype CLI

`anytype-cli.service` runs `anytype serve` as an unprivileged `anytype`
system user. It keeps a stable home and data directory under
`/var/lib/anytype`, which holds the bot's identity, Anytype state, and its
locally synchronized data. The service retains the CLI's default loopback
listener; its HTTP API is `127.0.0.1:31012`.

The upstream CLI's user-service installer is not used. NixOS owns lifecycle,
restart behavior, paths, and service hardening through the system unit.

### MCP Bridge

`anytype-mcp-proxy.service` runs Nixpkgs' `mcp-proxy`, bound to
`127.0.0.1:8118`. It launches `pkgs.anytype-mcp` as its only stdio
child and exposes the child's tools through Streamable HTTP at `/mcp`.

Its runtime environment selects the CLI API with
`ANYTYPE_API_BASE_URL=http://127.0.0.1:31012` and supplies the private
Anytype API authorization and API-version headers expected by the official
MCP package. It is a separate low-privilege account from the CLI service and
does not receive the CLI's state directory.

All upstream Anytype MCP tools remain available. The package's file-upload
operations may read a host path selected by a tool argument, so the MCP
bridge/child systemd sandbox is limited to a dedicated upload directory under
`/var/lib/anytype-mcp/uploads`. It cannot read the CLI state, encrypted secret
files, user homes, or general host files. This preserves the tool while making
the upload directory its explicit host-file capability boundary.

### Nginx Authentication and Proxying

Nginx is the sole public auth boundary. The role includes the encrypted file
`/etc/nixos/secrets/anytype-mcp-nginx-auth.conf` only inside the exact `/mcp`
location. The file will contain a generated base64url token in an Nginx
condition that returns `401` unless the request header is exactly:

```text
Authorization: Bearer <public-token>
```

This include keeps the expected token out of the Nix store, source tree, and
generated Nix configuration. It must be read by Nginx at service reload, so
the secret-installation specification will give it root ownership and a mode
that Nginx can safely consume during reload.

After authentication, Nginx proxies the request unchanged to the loopback
bridge. The bridge has no externally reachable listener, so the token cannot
be bypassed through a direct public connection.

## State, Secrets, and Backups

Three secret/state classes have different owners and revocation paths:

| Item | Location and owner | Rotation/revocation |
| --- | --- | --- |
| Public MCP bearer token | Encrypted Nginx include | Generate a new base64url token, update the encrypted include, reload Nginx, then update clients. |
| Private Anytype API key | Encrypted bridge environment file, readable only while systemd loads the bridge environment | Create/revoke through the headless CLI, update the encrypted file, restart the bridge. |
| Bot account and Anytype state | `/var/lib/anytype`, owned by the CLI user | Remove the bot from a space to revoke space access; retain recovery material outside the repository. |

The bridge environment file contains the official MCP package's backend
headers, including `Authorization: Bearer <private-anytype-api-key>` and the
required Anytype API-version header. It must never be included in Nix source,
the Nix store, or Nginx configuration.

The role adds `/var/lib/anytype` to `roles.backup.paths` so the existing restic
job stores it encrypted. This is a recovery copy of the headless bot state;
the bot's Anytype data is also synchronized through its joined spaces. The
implementation plan will document recovery by restoring ownership and state
before starting `anytype-cli.service`.

## Bootstrap and Normal Operations

After the role first deploys and the CLI is healthy, the operator performs
these non-declarative Anytype actions as the `anytype` service user:

1. Create the dedicated bot account with `anytype auth create` and retain its
   recovery material securely outside this repository.
2. Use Anytype invite links to join the bot only to desired spaces. Add and
   remove memberships manually as the authorization policy changes.
3. Create a separate API key with `anytype auth apikey create` for the MCP
   bridge.
4. Add that key to the encrypted bridge environment file and generate a
   high-entropy base64url public bearer token in the encrypted Nginx include.
5. Start or restart the bridge and configure compatible MCP clients with
   `https://anytype.uspenskiy.tech/mcp` plus the public bearer token.

The caller authenticated with the public bearer token acts with the complete
authority of the bot in every space the bot has joined. If the token is lost,
the operator rotates it; if a space should no longer be accessible, the
operator removes the bot from that space and may additionally revoke its
private Anytype API key.

The implementation will ensure `anytype.uspenskiy.tech` resolves to mokosh
through the repository's declarative DNS workflow before deployment. Existing
wildcard ACME certificate coverage does not itself create the DNS record.

## Failure Handling

- If `anytype-cli.service` is unavailable, the official MCP child cannot
  connect to `127.0.0.1:31012`; the bridge remains unhealthy and tool calls
  fail without exposing the raw CLI API.
- If the bridge or its stdio child exits, systemd restarts the bridge. A
  restart creates a fresh official MCP child and reconnects it to the CLI.
- If Nginx cannot read the authentication include, its configuration test or
  reload fails rather than serving an unintentionally unprotected endpoint.
- An invalid or revoked private Anytype API key causes tool calls to fail at
  the local API boundary; it does not change bot state or Nginx token
  validation.
- A compromised public token grants the same Anytype authority as the bot.
  Token rotation and removing the bot from spaces are the intended recovery
  actions.
- The service deliberately retains upstream logging behavior and transport
  defaults. Operational access to its journal is therefore restricted to host
  administrators.

## Verification

Implementation verification will cover:

1. Format changed Nix files with `nixfmt` and run `git diff --check`.
2. Evaluate the affected mokosh configuration and run `make check`, using
   dummy secrets when needed.
3. Confirm the `nix-anysync` overlay evaluates `anytype-cli`, `anytype-heart`,
   and `anytype-mcp` against this repository's pinned Nixpkgs.
4. Confirm both application listeners are loopback-only and that no new
   firewall port is configured.
5. Confirm an unauthenticated request to the public `/mcp` endpoint receives
   `401`, while all other host paths receive `404`.
6. From an MCP client configured with the bearer token, initialize the
   Streamable-HTTP session, list the full tool set, and run read, create,
   update, and delete operations in an explicitly invited test space.
7. Exercise a file-upload tool using a file placed in the dedicated upload
   directory, and confirm a request for a host secret or a file outside that
   directory fails.
8. Restart each systemd service and confirm the bot still lists its joined
   spaces and the public endpoint recovers.
9. Run the existing restic backup, confirm it contains the CLI state, and
   document the state-restore procedure.

## Expected File Changes

- `flake.nix`: add and pin the `nix-anysync` flake input; apply its overlay to
  mokosh only.
- `flake.lock`: record the new flake input.
- `roles/anytype-mcp.nix`: new role composing the CLI, bridge, sandbox,
  Nginx virtual host, and backup integration.
- `machines/mokosh/default.nix`: enable the role with
  `baseDomain = domainNames.secondary`.
- encrypted-secret specification: install the private bridge environment file
  and the Nginx bearer-token include on mokosh.
- declarative DNS configuration: add/confirm the `anytype` record through the
  repository's DNS-management workflow.
- operator documentation: record the exact bootstrap, rotation, and recovery
  commands discovered during implementation.
- `docs/superpowers/plans/2026-09-14-anytype-mcp-mokosh.md`: implementation
  plan, created only after this approved design is reviewed.

## Alternatives Considered

### Reverse-proxy the CLI API

Rejected. This would publicly publish the raw Anytype API and conflate the
public-client credential with the private local API key. The CLI specifically
keeps its API listener on loopback by default.

### Run `anytype-mcp` Directly

Rejected for remote clients. The official package starts an MCP stdio
transport, not an HTTP listener. Nginx cannot turn a stdio process into an MCP
HTTP server.

### Use `anytype-agent-runtime`

Rejected. It is a JavaScript automation runtime that consumes an existing
Anytype API URL/key/space. It supplies neither the synchronized headless node
nor the MCP transport required here.

### Fork the Official MCP Server to Add HTTP

Not selected. A local fork could own the Streamable-HTTP transport and bearer
authentication directly, but it would carry ongoing maintenance for upstream
tool-generation changes. The Nixpkgs bridge keeps the official MCP package
unchanged.

## Research Basis

The detailed upstream findings, source citations, package-version notes, and
security constraints are retained in
[the accompanying research note](../../research/2026-09-14-anytype-mcp-on-mokosh.md).
