# Public Anytype MCP on Mokosh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the complete Anytype MCP tool surface at `https://anytype.uspenskiy.tech/mcp`, backed by a dedicated headless Anytype bot on mokosh.

**Architecture:** The `nix-anysync` overlay provides the official Anytype CLI/Heart versions and official stdio-only MCP package. A loopback Anytype CLI API feeds that MCP child through Nixpkgs' Streamable-HTTP `mcp-proxy`; Nginx terminates TLS and performs static bearer-token validation before proxying `/mcp` to the loopback bridge.

**Tech Stack:** Nix flakes, NixOS systemd, Nginx, `wellWINeo/nix-anysync`, Nixpkgs `mcp-proxy`, Anytype CLI, official Anytype MCP, Cloudflare DNSControl, Restic.

## Global Constraints

- Use `inputs.nix-anysync.overlay` only in mokosh's overlay list; its `nixpkgs` input must follow this repository's `nixpkgs`.
- Use `pkgs.anytype-cli`, `pkgs.anytype-heart`, and `pkgs.anytype-mcp` from that overlay; do not package Anytype components in this repository.
- Use Nixpkgs `pkgs.mcp-proxy` as the stdio-to-Streamable-HTTP bridge.
- Publish exactly `https://anytype.uspenskiy.tech/mcp`; the bridge listens on `127.0.0.1:8118` and the CLI retains `127.0.0.1:31012`.
- Authenticate the public endpoint with one static `Authorization: Bearer` token validated by an encrypted Nginx include file.
- Keep the private Anytype API key distinct from the public bearer token and load it only through a root-owned systemd environment file.
- Keep every official Anytype MCP tool enabled. Restrict the MCP process's host-file access to `/var/lib/anytype-mcp/uploads` with systemd sandboxing.
- The operator manages bot creation and Anytype-space membership manually.
- Do not deploy Any-Sync, `anytype-agent-runtime`, OAuth, user accounts, an application UI, a custom package derivation, local MCP logging patches, explicit Origin/CORS policy, or request-rate limits.
- Do not add a public firewall port. Nginx's existing HTTPS listener is the only Internet-facing listener.
- Before changing or previewing declarative DNS, read the repository's `managing-dns` instructions and use its prescribed workflow.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `flake.nix` | Pins `nix-anysync`, aligns its Nixpkgs input, and enables the overlay only for mokosh. |
| `flake.lock` | Records the immutable flake input revision. |
| `roles/anytype-mcp.nix` | Defines the reusable role; owns service users, CLI and bridge units, filesystem sandboxing, Nginx virtual host, and restic integration. |
| `machines/mokosh/default.nix` | Enables the role with `domainNames.secondary`, yielding `anytype.uspenskiy.tech`. |
| `secrets/unlocked/spec.txt` | Declares deployment mode, owner, and group for the two encrypted mokosh files. It contains no secret values. |
| `secrets/unlocked/anytype-mcp.env` | Untracked encrypted-source file containing only `OPENAPI_MCP_HEADERS` with the private Anytype API key. |
| `secrets/unlocked/anytype-mcp-nginx-auth.conf` | Untracked encrypted-source Nginx include that validates the public bearer token. |
| `dns/zones/uspenskiy-tech.nix` | Declares the public `anytype` CNAME to mokosh. |
| `docs/anytype-mcp.md` | Operator bootstrap, rotation, recovery, and smoke-test runbook. |

## Task 1: Pin the Anytype Package Source for Mokosh

**Files:**

- Modify: `flake.nix:4-55`
- Modify: `flake.nix:80-94`
- Modify: `flake.lock`

**Interfaces:**

- Consumes: `nix-anysync.overlay`, which overrides `prev.anytype-cli` and `prev.anytype-heart` and exports `anytype-mcp`.
- Produces: `nixosConfigurations.mokosh.pkgs.anytype-cli`, `.anytype-heart`, and `.anytype-mcp` from one evaluated package set.

- [ ] **Step 1: Confirm the current configuration cannot resolve the external MCP package**

Run:

```bash
nix eval --raw .#nixosConfigurations.mokosh.pkgs.anytype-mcp.pname
```

Expected: evaluation fails because `anytype-mcp` is not in the current mokosh package set.

- [ ] **Step 2: Add the followed flake input**

In the `inputs` attrset in `flake.nix`, add the input next to the other service-package flakes:

```nix
nix-anysync = {
  url = "github:wellWINeo/nix-anysync";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Keep `nix-anysync` available through the existing `...@inputs` binding; do not add it to the `outputs` function's explicit destructuring.

- [ ] **Step 3: Apply the overlay only to mokosh**

Append the overlay to the existing mokosh-only `nixpkgs.overlays` list in
`flake.nix`, ahead of the local `miniflux-summarizer` overlay:

```nix
inputs.nix-anysync.overlay
```

The resulting machine-specific overlay block is conceptually:

```nix
nixpkgs.overlays = (import ./overlays) ++ [
  inputs.nix-anysync.overlay
  (final: prev: {
    miniflux-summarizer =
      inputs.miniflux-summarizer.packages.${prev.stdenv.hostPlatform.system}.default;
  })
];
```

Do not add this overlay to `nixpkgsFor`, other NixOS hosts, or Home Manager.

- [ ] **Step 4: Generate the lock entry and verify all Anytype package attributes**

Run:

```bash
nix flake lock --update-input nix-anysync
nix eval --raw .#nixosConfigurations.mokosh.pkgs.anytype-cli.pname
nix eval --raw .#nixosConfigurations.mokosh.pkgs.anytype-heart.pname
nix eval --raw .#nixosConfigurations.mokosh.pkgs.anytype-mcp.pname
```

Expected: all three evaluations return package names, and the lockfile changes
only for the new `nix-anysync` input and its referenced nodes.

- [ ] **Step 5: Run the flake check with dummy JSON secrets**

Run:

```bash
make setup-dummy-secrets
make check
```

Expected: `nix flake check 'path:.' --all-systems` succeeds. If this reveals a
base-package incompatibility in the overlay, stop here and update the
`nix-anysync` pin or its overlay; do not introduce a duplicate Anytype
derivation in this repository.

- [ ] **Step 6: Commit the pinned input**

```bash
git add flake.nix flake.lock
git commit -m "feat: add nix-anysync overlay for mokosh"
```

## Task 2: Add the Anytype MCP Role and Enable It on Mokosh

**Files:**

- Create: `roles/anytype-mcp.nix`
- Modify: `machines/mokosh/default.nix:26-177`

**Interfaces:**

- Consumes: `pkgs.anytype-cli`, `pkgs.anytype-mcp`, and `pkgs.mcp-proxy`; `/etc/nixos/secrets/anytype-mcp.env`; the `roles.backup` option interface; and the existing `uspenskiy.tech` ACME certificate.
- Produces: `roles.anytype-mcp.enable`, `roles.anytype-mcp.baseDomain`, `anytype-cli.service`, `anytype-mcp-proxy.service`, and the Nginx host `anytype.uspenskiy.tech`.

- [ ] **Step 1: Establish the failing role-evaluation check**

Run:

```bash
nix eval --raw .#nixosConfigurations.mokosh.config.roles.anytype-mcp.baseDomain
```

Expected: evaluation fails because the role option does not yet exist.

- [ ] **Step 2: Create the focused role interface and local constants**

Create `roles/anytype-mcp.nix` using the repository's role style. Start it
with these exact public options and local values:

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.anytype-mcp;
  hostname = "anytype.${cfg.baseDomain}";
  cliPort = 31012;
  bridgePort = 8118;
  cliDataDir = "/var/lib/anytype";
  bridgeDataDir = "/var/lib/anytype-mcp";
  uploadDir = "${bridgeDataDir}/uploads";
in
{
  options.roles.anytype-mcp = {
    enable = mkEnableOption "public Anytype MCP service";
    baseDomain = mkOption {
      type = types.str;
      description = "Base domain used for the public Anytype MCP hostname";
    };
  };

  config = mkIf cfg.enable {
    # Service users, units, Nginx, and backup integration go here.
  };
}
```

Keep package versions, ports, secret paths, and service users internal to the
role so a machine only supplies the base domain.

- [ ] **Step 3: Implement the persistent headless CLI service**

Inside the enabled configuration, declare a system `anytype` group and user
and the service below. The `HOME` and `DATA_PATH` variables ensure the bot
state is independent of the login shell or root home directory.

```nix
users.groups.anytype = { };
users.users.anytype = {
  isSystemUser = true;
  group = "anytype";
  home = cliDataDir;
  createHome = true;
};

systemd.services.anytype-cli = {
  description = "Anytype headless CLI";
  after = [ "network-online.target" ];
  wants = [ "network-online.target" ];
  wantedBy = [ "multi-user.target" ];
  environment = {
    HOME = cliDataDir;
    DATA_PATH = cliDataDir;
  };
  serviceConfig = {
    User = "anytype";
    Group = "anytype";
    StateDirectory = "anytype";
    WorkingDirectory = cliDataDir;
    ExecStart = "${pkgs.anytype-cli}/bin/anytype serve";
    Restart = "on-failure";
    RestartSec = "5s";
    NoNewPrivileges = true;
    PrivateTmp = true;
  };
};

environment.systemPackages = [ pkgs.anytype-cli ];
```

Do not change the CLI listener to `0.0.0.0`; its default API endpoint remains
`127.0.0.1:31012`. Adding the package to the system profile makes the exact
`anytype` operator commands in Task 4 available to the service user without
embedding a Nix store path in the runbook.

- [ ] **Step 4: Implement the sandboxed MCP bridge service**

Declare an independent `anytype-mcp` system user/group, create the upload
directory, and add a bridge unit that starts only after the CLI:

```nix
users.groups.anytype-mcp = { };
users.users.anytype-mcp = {
  isSystemUser = true;
  group = "anytype-mcp";
  home = bridgeDataDir;
  createHome = true;
};

systemd.tmpfiles.rules = [
  "d ${uploadDir} 0700 anytype-mcp anytype-mcp -"
];

systemd.services.anytype-mcp-proxy = {
  description = "Anytype Streamable HTTP MCP bridge";
  after = [ "anytype-cli.service" ];
  requires = [ "anytype-cli.service" ];
  wantedBy = [ "multi-user.target" ];
  environment = {
    ANYTYPE_API_BASE_URL = "http://127.0.0.1:${toString cliPort}";
  };
  serviceConfig = {
    User = "anytype-mcp";
    Group = "anytype-mcp";
    StateDirectory = "anytype-mcp";
    WorkingDirectory = bridgeDataDir;
    EnvironmentFile = "/etc/nixos/secrets/anytype-mcp.env";
    ExecStart = "${pkgs.mcp-proxy}/bin/mcp-proxy --host 127.0.0.1 --port ${toString bridgePort} --pass-environment -- ${pkgs.anytype-mcp}/bin/anytype-mcp";
    Restart = "on-failure";
    RestartSec = "5s";
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    InaccessiblePaths = [
      "/etc/nixos/secrets"
      cliDataDir
      "/home"
      "/root"
    ];
    ReadWritePaths = [ uploadDir ];
  };
};
```

`--pass-environment` is required: it passes the systemd-loaded
`OPENAPI_MCP_HEADERS` to the official stdio child. Do not place that header or
the private Anytype API key in an `environment = { ... };` Nix attrset, which
would put it in the Nix store.

- [ ] **Step 5: Add Nginx exposure and restic integration to the same role**

Add the backup path and exact Nginx routes within `mkIf cfg.enable`:

```nix
roles.backup.paths = [ cliDataDir ];

services.nginx.virtualHosts.${hostname} = {
  forceSSL = true;
  enableACME = false;
  sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
  sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";

  locations."= /mcp" = {
    proxyPass = "http://127.0.0.1:${toString bridgePort}";
    recommendedProxySettings = true;
    extraConfig = ''
      include /etc/nixos/secrets/anytype-mcp-nginx-auth.conf;
      proxy_buffering off;
      proxy_read_timeout 300s;
    '';
  };

  locations."/".extraConfig = ''
    return 404;
  '';
};
```

The encrypted include must run before `proxyPass` and return `401` on a token
mismatch. Do not add an Nginx location for the CLI's `31012` API, the bridge's
SSE route, health/status routes, or the upload directory.

- [ ] **Step 6: Enable the role on mokosh**

In the roles section of `machines/mokosh/default.nix`, add:

```nix
roles.anytype-mcp = {
  enable = true;
  baseDomain = domainNames.secondary;
};
```

This derives `anytype.uspenskiy.tech`, matching the existing wildcard
certificate directory `/var/lib/acme/uspenskiy.tech`.

- [ ] **Step 7: Evaluate the complete generated service interface**

Run:

```bash
nix eval --raw .#nixosConfigurations.mokosh.config.roles.anytype-mcp.baseDomain
nix eval --raw .#nixosConfigurations.mokosh.config.systemd.services.anytype-cli.serviceConfig.ExecStart
nix eval --raw .#nixosConfigurations.mokosh.config.systemd.services.anytype-mcp-proxy.serviceConfig.ExecStart
nix eval --json .#nixosConfigurations.mokosh.config.networking.firewall.allowedTCPPorts
make check
```

Expected: the base domain is `uspenskiy.tech`; the generated commands use
`anytype serve`, `--host 127.0.0.1 --port 8118`, and `anytype-mcp`; the
firewall output has no `8118` or `31012`; and the flake check succeeds.

- [ ] **Step 8: Commit the role composition**

```bash
git add roles/anytype-mcp.nix machines/mokosh/default.nix
git commit -m "feat: add public Anytype MCP role for mokosh"
```

## Task 3: Declare Secrets and the Public DNS Record

**Files:**

- Modify: `secrets/unlocked/spec.txt:2-31`
- Create (untracked, then encrypted): `secrets/unlocked/anytype-mcp.env`
- Create (untracked, then encrypted): `secrets/unlocked/anytype-mcp-nginx-auth.conf`
- Modify: `dns/zones/uspenskiy-tech.nix:1-88`

**Interfaces:**

- Consumes: the role paths `/etc/nixos/secrets/anytype-mcp.env` and `/etc/nixos/secrets/anytype-mcp-nginx-auth.conf`; `mokosh.uspenskiy.tech.`; and the existing secrets lock/install workflow.
- Produces: root-only installed files consumed by systemd/Nginx, and the public DNS name `anytype.uspenskiy.tech` resolving directly to mokosh.

- [ ] **Step 1: Add the failing DNS declaration check**

Read the repository DNS-management instructions before running any DNS
preview. Then inspect the rendered declaration:

```bash
nix eval --impure --json --expr '
  let
    flake = builtins.getFlake (toString ./.);
    pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
    renderer = import ./dns/lib.nix { inherit (pkgs) lib; };
  in renderer.render (import ./dns/zones)
' | jq -e '
  [.domains[] | select(.name == "uspenskiy.tech") | .records[]
   | select(.name == "anytype")]
  | length == 1
'
```

Expected: the command fails because the `anytype` record has not yet been
declared.

- [ ] **Step 2: Declare both encrypted secret-file installations**

Add these two lines to `secrets/unlocked/spec.txt` with the other mokosh
entries:

```text
mokosh:anytype-mcp.env:0400:root:root
mokosh:anytype-mcp-nginx-auth.conf:0400:root:root
```

The files themselves remain ignored by Git and are included only through
`secrets/locked.tar.gpg` after the operator runs `make lock-files`.

- [ ] **Step 3: Create the bridge's private API-key environment file**

After Task 2 is deployed enough for the CLI to run and the bot API key exists,
create `secrets/unlocked/anytype-mcp.env` mode `0400` with exactly one
environment assignment. Substitute the API key produced by
`anytype auth apikey create "anytype-mcp"`:

```text
OPENAPI_MCP_HEADERS='{"Authorization":"Bearer ACTUAL_ANYTYPE_API_KEY","Anytype-Version":"2025-11-08"}'
```

Use an editor or secret manager that does not record the key in shell history.
Do not add `ANYTYPE_API_BASE_URL` to this file; that non-secret value stays in
the Nix role. Confirm the value ends with a newline and is valid systemd
`EnvironmentFile` syntax.

- [ ] **Step 4: Create the static-bearer Nginx include**

Generate a high-entropy base64url token in the operator's secret manager and
write `secrets/unlocked/anytype-mcp-nginx-auth.conf`, mode `0400`, with this
single Nginx condition. Replace `ACTUAL_BASE64URL_TOKEN` only in the
untracked secret file:

```nginx
if ($http_authorization != "Bearer ACTUAL_BASE64URL_TOKEN") { return 401; }
```

Use an alphabet restricted to `A-Z`, `a-z`, `0-9`, `-`, and `_` so the token
cannot alter Nginx syntax. The value is the only public-client credential; it
is not the private Anytype API key.

- [ ] **Step 5: Declare the unproxied public hostname**

Add this record to `dns/zones/uspenskiy-tech.nix` alongside the existing
mokosh service CNAME records:

```nix
{
  type = "CNAME";
  name = "anytype";
  target = "mokosh.uspenskiy.tech.";
  proxied = false;
  ttl = "auto";
}
```

Keep it unproxied so the Streamable-HTTP endpoint has a direct TLS connection
to Nginx and is not subject to a CDN request-duration or streaming policy.

- [ ] **Step 6: Verify the declaration and encrypted secret bundle without exposing values**

Run:

```bash
nix eval --impure --json --expr '
  let
    flake = builtins.getFlake (toString ./.);
    pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
    renderer = import ./dns/lib.nix { inherit (pkgs) lib; };
  in renderer.render (import ./dns/zones)
' | jq -e '
  [.domains[] | select(.name == "uspenskiy.tech") | .records[]
   | select(.name == "anytype" and .type == "CNAME"
     and .target == "mokosh.uspenskiy.tech."
     and .meta.cloudflare_proxy == "off")]
  | length == 1
'
make lock-files
git diff --check
```

Expected: the DNS assertion succeeds; `locked.tar.gpg` changes; no plaintext
secret file appears in `git status`; and whitespace validation succeeds.

- [ ] **Step 7: Preview and apply DNS through the managed workflow**

With `CLOUDFLARE_DNS_TOKEN` supplied only by the operator's secret manager,
run the workflow required by the DNS skill:

```bash
nix run .#dns-preview -- uspenskiy.tech
nix run .#dns-apply -- --confirm uspenskiy.tech
```

Expected: preview adds only the unproxied `anytype` CNAME. Apply only after
that exact change is reviewed and no concurrent CI apply is pending.

- [ ] **Step 8: Commit declarative metadata, never plaintext secrets**

```bash
git add secrets/unlocked/spec.txt secrets/locked.tar.gpg dns/zones/uspenskiy-tech.nix
git commit -m "feat: declare Anytype MCP secrets and DNS"
```

## Task 4: Bootstrap the Bot, Deploy Mokosh, and Write the Operator Runbook

**Files:**

- Create: `docs/anytype-mcp.md`
- Modify: `secrets/locked.tar.gpg`

**Interfaces:**

- Consumes: deployed `anytype-cli.service`, the two installed secret paths, and the public `anytype.uspenskiy.tech/mcp` endpoint.
- Produces: a durable bot identity with operator-controlled space membership, working static-bearer MCP access, and a tested recovery procedure.

- [ ] **Step 1: Confirm the pre-bootstrap API is unavailable before the CLI service is deployed**

From mokosh before switching, run:

```bash
curl --fail http://127.0.0.1:31012/docs/openapi.json
```

Expected: connection failure because the new CLI service is not yet running.

- [ ] **Step 2: Build and switch the mokosh configuration**

On mokosh, install decrypted files and switch only after the Nix evaluation
from Task 2 passes:

```bash
make install-secrets
sudo nixos-rebuild switch --flake 'path:.#mokosh'
sudo systemctl status anytype-cli.service anytype-mcp-proxy.service nginx.service
sudo ss -ltnp | rg ':(31012|8118)\b'
```

Expected: both service units are active; listeners for ports `31012` and
`8118` show `127.0.0.1`, never a public address.

- [ ] **Step 3: Create and scope the dedicated bot as the service user**

Run the CLI as its owning system user with the same persistent environment as
the service:

```bash
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype auth create anytype-mcp
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype auth apikey create anytype-mcp
```

Store the bot recovery material outside the repository. Join spaces using
the Anytype invite link copied directly from Anytype as the quoted positional
argument, then verify the intended scope:

```bash
read -r ANYTYPE_INVITE_LINK
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype space join "$ANYTYPE_INVITE_LINK"
unset ANYTYPE_INVITE_LINK
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype space list
```

Only join a disposable test space during initial validation.

- [ ] **Step 4: Install the generated secrets and restart only the consumers**

After putting the newly generated private API key and public token in the two
files described by Task 3, re-encrypt and install them:

```bash
make lock-files
make install-secrets
sudo systemctl restart anytype-mcp-proxy.service
sudo systemctl reload nginx.service
```

Expected: the bridge starts after loading the private environment and Nginx
reloads after reading the bearer-token include. Neither command prints either
credential.

- [ ] **Step 5: Run an unauthenticated and authenticated Streamable-HTTP smoke test**

On a trusted client, obtain the public token from its secret manager without
printing it, then run:

```bash
read -rs MCP_TOKEN
printf '\n'
curl -sS -D /tmp/anytype-mcp.headers -o /tmp/anytype-mcp.body \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"mokosh-smoke","version":"1"}}}' \
  https://anytype.uspenskiy.tech/mcp
curl -sS -D /tmp/anytype-mcp-auth.headers -o /tmp/anytype-mcp-auth.body \
  -H "Authorization: Bearer $MCP_TOKEN" \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Content-Type: application/json' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"mokosh-smoke","version":"1"}}}' \
  https://anytype.uspenskiy.tech/mcp
unset MCP_TOKEN
```

Expected: the first response status is `401`; the authenticated response is a
successful MCP initialization and includes an `Mcp-Session-Id` response header
when the bridge selects a sessionful transport. Use that session ID with the
same bearer token to call `tools/list`, then create, update, read, and delete
a test object in the bot's invited test space. Copy no object content or token
into the repository or journal.

- [ ] **Step 6: Verify sandbox and persistence behavior**

Place one disposable file in `/var/lib/anytype-mcp/uploads` owned by
`anytype-mcp`, then invoke the upstream file-upload tool through the
authenticated MCP client. Confirm it succeeds. Attempt the same tool with
`/etc/nixos/secrets/restic-password` and confirm it fails with a permission or
not-found error.

Restart the services and confirm the bot still lists its joined spaces:

```bash
sudo systemctl restart anytype-cli.service anytype-mcp-proxy.service
sudo -u anytype env HOME=/var/lib/anytype DATA_PATH=/var/lib/anytype \
  anytype space list
sudo systemctl start restic-backups-local.service
```

Expected: the test space remains joined, the public MCP endpoint recovers,
and the restic job completes with `/var/lib/anytype` in its configured path
set.

- [ ] **Step 7: Write the operator runbook**

Create `docs/anytype-mcp.md` with these exact sections:

```markdown
# Anytype MCP on Mokosh

## Endpoint and Client Authentication
## Initial Bot Bootstrap
## Adding and Removing Space Access
## Rotating the Public Bearer Token
## Rotating the Private Anytype API Key
## Upload Directory Boundary
## Service Health and Logs
## Backup and State Recovery
```

Document the commands from Steps 2–6 using real service names and paths. State
plainly that the static bearer has all authority held by the bot, that all MCP
tools are enabled, that files must first be placed in
`/var/lib/anytype-mcp/uploads`, and that membership changes are performed in
Anytype rather than Nix.

- [ ] **Step 8: Final repository validation and commit**

Run:

```bash
git diff --check
make check
git status --short
```

Expected: there are no whitespace errors, the flake check succeeds, and no
plaintext `secrets/unlocked/anytype-mcp*` file is staged or untracked for Git.

Commit only the runbook and the updated encrypted archive if it changed:

```bash
git add docs/anytype-mcp.md secrets/locked.tar.gpg
git commit -m "docs: add Anytype MCP operator runbook"
```

## Spec Coverage Review

- Public path, TLS, bearer authentication, and no new firewall port are implemented in Task 2 and exercised in Task 4.
- The existing `nix-anysync` Anytype packages and Nixpkgs bridge are pinned and evaluated in Task 1.
- Dedicated bot state, loopback-only CLI API, separate bridge user, full tool set, and upload-directory sandbox are implemented in Task 2.
- Two separate secrets, encrypted state backup, declarative DNS, and token/API-key rotation are implemented in Tasks 2–4.
- Manual Anytype membership, recovery, persistence, and read/write/delete/file smoke tests are covered in Task 4.
- The user-approved omissions—Any-Sync, agent runtime, OAuth, tool reduction, local log patch, explicit Origin/CORS controls, and rate limits—are preserved in the global constraints and no task introduces them.
