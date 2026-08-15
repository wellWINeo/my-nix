# Readeck on Mokosh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Readeck on `mokosh` at `readlater.uspenskiy.tech` with the native NixOS module, a local SQLite database, encrypted secret configuration, and restic-backed persistence.

**Architecture:** Add a standalone `roles.readeck` module at `roles/reading/readeck.nix`. The role configures the pinned `services.readeck` module to listen on `127.0.0.1:8000`, adds an HTTPS Nginx virtual host, and reuses `common/sqlite-backup.nix` before the existing restic backup. Enable it from `machines/mokosh/default.nix`; create the first Readeck user once after deployment through the CLI.

**Tech Stack:** Nix flakes, NixOS modules, nixpkgs `services.readeck`, Readeck `0.22.3`, systemd, Nginx, SQLite, restic, encrypted NixOS secrets, `nixfmt`, `nix eval`, `make check`, `curl`, and `ss`.

## Global Constraints

- The public hostname is exactly `readlater.uspenskiy.tech`.
- The service runs on `mokosh` and uses `domainNames.secondary` as its base domain.
- Place the role at `roles/reading/readeck.nix` and expose it as `roles.readeck`.
- Use the pinned nixpkgs `services.readeck` module and default package.
- Bind Readeck to `127.0.0.1:8000`; do not open port `8000` in the firewall.
- Use SQLite at `/var/lib/readeck/db.sqlite3` and keep state under `/var/lib/readeck`.
- Use `/etc/nixos/secrets/readeck.env` for a stable `READECK_SECRET_KEY`.
- Back up the database and state through `common/sqlite-backup.nix` and `roles.backup`.
- Create the first account once after deployment with `readeck user`; do not add a bootstrap systemd unit.
- Do not add Wallabag, PostgreSQL, a container runtime, a custom Readeck derivation, a flake input, a lockfile change, or an automated test framework.
- Do not commit changes unless the user explicitly requests a commit.

---

## File Structure

| File | Action | Responsibility |
| --- | --- | --- |
| `roles/reading/readeck.nix` | create | Declare `roles.readeck` and configure Readeck, Nginx, SQLite snapshots, and backup ordering. |
| `machines/mokosh/default.nix` | modify | Enable Readeck with `domainNames.secondary`. |
| `README.md` | modify | List Readeck under reading roles and document its hostname and loopback boundary. |
| `secrets/unlocked/spec.txt` | modify | Declare the encrypted `readeck.env` deployment file. |
| `secrets/unlocked/readeck.env` | create outside tracked source | Hold the real stable `READECK_SECRET_KEY`; it must remain encrypted and untracked. |
| `docs/superpowers/specs/2026-08-02-readeck-mokosh-design.md` | existing | Approved design for this implementation. |
| `docs/superpowers/plans/2026-08-02-readeck-mokosh.md` | create | This implementation plan. |

No changes are planned for `flake.nix`, `flake.lock`, `common/sqlite-backup.nix`, `roles/reading/calibre.nix`, or the existing RSS modules.

## Task 1: Add the Readeck Role

**Files:**
- Create: `roles/reading/readeck.nix`

**Interfaces:**
- Consumes: NixOS `services.readeck`, `common/sqlite-backup.nix`, `roles.backup`, and `config.roles.readeck.baseDomain`.
- Produces: `options.roles.readeck.enable`, `options.roles.readeck.baseDomain`, `services.readeck`, the `readlater.<baseDomain>` Nginx virtual host, and `backup-readeck.service`.

- [ ] **Step 1: Create the standalone role module**

Create `roles/reading/readeck.nix` with this module:

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.readeck;
  hostname = "readlater.${cfg.baseDomain}";
  port = 8000;
  dataDir = "/var/lib/readeck";
  backupDir = "/var/backup/readeck";
  mkSqliteBackup = import ../../common/sqlite-backup.nix;
in
{
  options.roles.readeck = {
    enable = mkEnableOption "Enable Readeck";
    baseDomain = mkOption {
      type = types.str;
      description = "2nd level domain name (base)";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkSqliteBackup {
      inherit lib pkgs;
      name = "readeck";
      databases = [ "${dataDir}/db.sqlite3" ];
      backupDir = backupDir;
      user = "root";
      group = "root";
      extraPaths = [ "${dataDir}/" ];
    })
    {
      roles.backup.paths = [ backupDir ];
      roles.backup.afterServices = [ "backup-readeck.service" ];

      services.readeck = {
        enable = true;
        environmentFile = "/etc/nixos/secrets/readeck.env";
        settings = {
          main.data_directory = dataDir;
          server = {
            host = "127.0.0.1";
            port = port;
            allowed_hosts = [ hostname ];
            trusted_proxies = [ "127.0.0.1" ];
            base_url = "https://${hostname}";
          };
          database.source = "sqlite3:${dataDir}/db.sqlite3";
        };
      };

      services.nginx.virtualHosts.${hostname} = {
        forceSSL = true;
        enableACME = false;
        sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString port}";
          recommendedProxySettings = true;
        };
        extraConfig = ''
          client_max_body_size 50M;
          proxy_buffering off;
        '';
      };
    }
  ]);
}
```

The module must not add a static Readeck user or group. The native service's dynamic user owns its `StateDirectory`, while the root backup helper reads that state without changing the service model.

- [ ] **Step 2: Format the new module**

Run:

```bash
nix develop --command nixfmt roles/reading/readeck.nix
```

Expected: exit code `0`; the file remains equivalent to the module above and no other file changes.

## Task 2: Enable and Document Readeck

**Files:**
- Modify: `machines/mokosh/default.nix:162-181`
- Modify: `README.md:46-49` and the reading/service documentation section
- Modify: `secrets/unlocked/spec.txt`

**Interfaces:**
- Consumes: `roles.readeck` from Task 1 and the existing `domainNames.secondary` value.
- Produces: enabled Readeck configuration on `mokosh`, the documented public hostname, and a secrets installation rule.

- [ ] **Step 1: Enable Readeck on mokosh**

Add this block after the existing Calibre role and before the RSS role in `machines/mokosh/default.nix`:

```nix
  roles.readeck = {
    enable = true;
    baseDomain = domainNames.secondary;
  };
```

Keep the existing Calibre and RSS configuration unchanged.

- [ ] **Step 2: Update the README role inventory**

Change the reading tree from:

```text
│   ├── reading/             # Reading apps
│   │   ├── calibre.nix
│   │   └── rss/             #   miniflux + RSSHub + summarizer + backup
```

to:

```text
│   ├── reading/             # Reading apps
│   │   ├── calibre.nix
│   │   ├── readeck.nix
│   │   └── rss/             #   miniflux + RSSHub + summarizer + backup
```

- [ ] **Step 3: Document the deployed boundary**

Add this paragraph after the existing RSSHub paragraph in `README.md`:

```markdown
Readeck is enabled on `mokosh` as `roles.readeck` and is available at
`https://readlater.uspenskiy.tech`. It listens only on `127.0.0.1:8000` behind
Nginx, uses SQLite under `/var/lib/readeck`, and is included in the existing
encrypted backup flow.
```

- [ ] **Step 4: Declare the encrypted secret file**

Add this exact line to `secrets/unlocked/spec.txt`:

```text
mokosh:readeck.env:0400:root:root
```

Do not put the secret value in `secrets.json`, the Nix role, the README, or this plan.

- [ ] **Step 5: Create and encrypt the real environment file outside tracked source**

On a machine authorized to manage the encrypted secrets, after the secrets archive is unlocked, create the file only if it does not already exist:

```bash
test ! -e secrets/unlocked/readeck.env
umask 077
printf 'READECK_SECRET_KEY=%s\n' "$(openssl rand -hex 32)" > secrets/unlocked/readeck.env
make lock
```

Expected: the file is included in the encrypted archive and remains ignored by Git. Never print its contents or add it to a patch.

- [ ] **Step 6: Format the machine configuration**

Run:

```bash
nix develop --command nixfmt machines/mokosh/default.nix
```

Expected: exit code `0` with no unrelated formatting changes.

## Task 3: Evaluate and Validate the Declarative Configuration

**Files:**
- Test: `nixosConfigurations.mokosh`
- Test: `services.readeck`, Nginx, backup, and firewall evaluation

**Interfaces:**
- Consumes: the role, machine enablement, and encrypted-secret specification from Tasks 1 and 2.
- Produces: evidence that Readeck is configured with the intended host, port, SQLite source, backup path, and loopback boundary.

- [ ] **Step 1: Ensure validation secrets exist without replacing real secrets**

Run:

```bash
test -f secrets/secrets.json || make setup-dummy-secrets
```

Expected: `secrets/secrets.json` exists. An existing real or dummy file is not overwritten.

- [ ] **Step 2: Format all changed Nix files**

Run:

```bash
nix develop --command nixfmt \
  roles/reading/readeck.nix \
  machines/mokosh/default.nix
```

Expected: exit code `0` and no formatting changes after the command completes.

- [ ] **Step 3: Evaluate the selected Readeck and backup settings**

Run:

```bash
nix eval --impure --json --expr '
  let
    cfg = (builtins.getFlake (toString ./.)).nixosConfigurations.mokosh.config;
  in {
    roleEnabled = cfg.roles.readeck.enable;
    serviceEnabled = cfg.services.readeck.enable;
    serviceHost = cfg.services.readeck.settings.server.host;
    servicePort = cfg.services.readeck.settings.server.port;
    allowedHosts = cfg.services.readeck.settings.server.allowed_hosts;
    baseUrl = cfg.services.readeck.settings.server.base_url;
    database = cfg.services.readeck.settings.database.source;
    environmentFile = cfg.services.readeck.environmentFile;
    nginxProxy = cfg.services.nginx.virtualHosts."readlater.uspenskiy.tech".locations."/".proxyPass;
    backupPath = builtins.elem "/var/backup/readeck" cfg.roles.backup.paths;
    backupOrdering = builtins.elem "backup-readeck.service" cfg.roles.backup.afterServices;
    firewallExposesPort = builtins.elem 8000 cfg.networking.firewall.allowedTCPPorts;
  }
'
```

Expected values include:

```json
{
  "allowedHosts": ["readlater.uspenskiy.tech"],
  "backupOrdering": true,
  "backupPath": true,
  "baseUrl": "https://readlater.uspenskiy.tech",
  "database": "sqlite3:/var/lib/readeck/db.sqlite3",
  "environmentFile": "/etc/nixos/secrets/readeck.env",
  "firewallExposesPort": false,
  "nginxProxy": "http://127.0.0.1:8000",
  "roleEnabled": true,
  "serviceEnabled": true,
  "serviceHost": "127.0.0.1",
  "servicePort": 8000
}
```

- [ ] **Step 4: Confirm the pinned Readeck package**

Run:

```bash
nix eval --raw 'path:.#nixosConfigurations.mokosh.pkgs.readeck.version'
```

Expected:

```text
0.22.3
```

- [ ] **Step 5: Confirm the package is substitutable from the official cache**

Run:

```bash
READECK_OUT=$(nix eval --raw 'path:.#nixosConfigurations.mokosh.pkgs.readeck.outPath')
nix path-info --store https://cache.nixos.org "$READECK_OUT"
```

Expected: the command prints the same `/nix/store/...-readeck-0.22.3` path and does not build the package locally.

- [ ] **Step 6: Run the complete flake check**

Run:

```bash
make check
```

Expected: exit code `0` with no missing-option, Readeck module, Nginx, backup, or evaluation errors.

## Task 4: Deploy and Perform the One-Time Setup

**Files:**
- Deploy: `nixosConfigurations.mokosh`
- Runtime secret: `/etc/nixos/secrets/readeck.env`

**Interfaces:**
- Consumes: the validated role and encrypted secret archive from Tasks 1-3.
- Produces: an active Readeck service, a first `o__ni` admin account, and a reachable HTTPS application.

- [ ] **Step 1: Install the encrypted secret on mokosh**

On `mokosh`, unlock the encrypted files and install them according to `secrets/unlocked/spec.txt`:

```bash
make unlock
sudo make install-secrets
sudo test -r /etc/nixos/secrets/readeck.env
```

Expected: `/etc/nixos/secrets/readeck.env` exists with mode `0400`, owner `root`, group `root`, and its contents are not printed.

- [ ] **Step 2: Apply the NixOS configuration**

Run on `mokosh`:

```bash
make switch
```

Expected: `nixos-rebuild` completes successfully, `readeck.service` is enabled, and the Readeck package is obtained from the binary cache.

- [ ] **Step 3: Confirm the native service is active**

Run:

```bash
systemctl is-active --quiet readeck.service
```

Expected: exit code `0`.

- [ ] **Step 4: Locate the generated native configuration and package binary**

Run:

```bash
service_exec=$(systemctl show readeck.service --property=ExecStart --value)
config_path=$(printf '%s\n' "$service_exec" | sed -n 's/.*-config \([^; ]*\).*/\1/p')
readeck_bin="$(nix eval --raw 'path:.#nixosConfigurations.mokosh.config.services.readeck.package')/bin/readeck"
test -r "$config_path"
test -x "$readeck_bin"
```

Expected: both variables resolve to the generated TOML configuration and the package's executable without exposing the Readeck secret.

- [ ] **Step 5: Create the first Readeck account once**

Run the CLI as a transient root command so it can read the dynamic-user-owned SQLite database and the service's environment file:

```bash
sudo systemd-run --wait --pipe --collect \
  --property=EnvironmentFile=/etc/nixos/secrets/readeck.env \
  --property=WorkingDirectory=/var/lib/readeck \
  "$readeck_bin" user \
  -config "$config_path" \
  -user o__ni \
  -email stepan@uspenskiy.su \
  -group admin
```

Expected: Readeck prompts for the new password, creates the `o__ni` administrator, and exits successfully. Do not pass the password as a command-line argument.

- [ ] **Step 6: Confirm Readeck responds on loopback**

Run:

```bash
curl --fail --silent --show-error \
  'http://127.0.0.1:8000/login?r=%2F' \
  | grep -q 'Readeck'
```

Expected: exit code `0`, proving that the native service serves its login page locally.

- [ ] **Step 7: Confirm the public HTTPS route**

Run on `mokosh`:

```bash
curl --fail --silent --show-error \
  --resolve readlater.uspenskiy.tech:443:127.0.0.1 \
  'https://readlater.uspenskiy.tech/login?r=%2F' \
  | grep -q 'Readeck'
```

Expected: exit code `0` with a valid TLS response through Nginx. Then open `https://readlater.uspenskiy.tech` in a browser and log in with the account created in Step 5.

- [ ] **Step 8: Confirm loopback-only listening**

Run:

```bash
listeners=$(ss -ltnH 'sport = :8000')
printf '%s\n' "$listeners" | grep -Eq '127\.0\.0\.1:8000'
! printf '%s\n' "$listeners" | grep -Eq '0\.0\.0\.0:8000|\*:[0-9]+|\[::\]:8000'
```

Expected: the service listens on `127.0.0.1:8000` and not on an external IPv4 or IPv6 address.

- [ ] **Step 9: Run the Readeck snapshot backup**

Run:

```bash
sudo systemctl start backup-readeck.service
sudo test -s /var/backup/readeck/db.sqlite3
sudo test -d /var/backup/readeck
sudo journalctl -u backup-readeck.service -n 20 --no-pager
```

Expected: the oneshot exits successfully, the SQLite snapshot is non-empty, and the journal contains no backup error. The existing restic backup remains ordered after this snapshot service.

## Task 5: Final Review

**Files:**
- Review: all files changed by Tasks 1-4

**Interfaces:**
- Consumes: the role, machine configuration, documentation, encrypted-secret specification, validation output, and runtime smoke-test results.
- Produces: a clean, scoped change set ready for user review or an explicitly requested commit.

- [ ] **Step 1: Check whitespace errors**

Run:

```bash
git diff --check
```

Expected: no output and exit code `0`.

- [ ] **Step 2: Review the final status**

Run:

```bash
git status --short
```

Expected tracked or untracked feature paths are limited to:

```text
README.md
machines/mokosh/default.nix
roles/reading/readeck.nix
secrets/unlocked/spec.txt
docs/superpowers/specs/2026-08-02-readeck-mokosh-design.md
docs/superpowers/plans/2026-08-02-readeck-mokosh.md
```

`secrets/unlocked/readeck.env`, `secrets/secrets.json`, generated files, `flake.lock`, and unrelated changes must not be staged or committed.

- [ ] **Step 3: Repeat the complete validation**

Run:

```bash
make check
```

Expected: exit code `0` after the final diff review.

No commit is created as part of this plan unless the user explicitly requests one.

## Self-Review

- **Spec coverage:** Tasks 1 and 2 implement the native `roles.readeck` module, `mokosh` enablement, domain, encrypted secret declaration, Nginx boundary, SQLite path, and backup integration. Task 3 evaluates every declarative requirement and runs the flake check. Task 4 covers secret installation, deployment, one-time user creation, HTTPS, loopback binding, and snapshot backup. Task 5 checks final scope and repeats validation.
- **Placeholder scan:** No step depends on a deferred marker, unspecified file, unspecified port, unspecified domain, or unspecified command. The only generated value is the secret key, which is intentionally generated locally and never printed or committed.
- **Type consistency:** `roles.readeck.enable` and `roles.readeck.baseDomain` are declared in Task 1 and consumed by the exact `roles.readeck` block in Task 2. The settings names in Task 3 match the nested `services.readeck.settings` values in Task 1. The backup unit names match `common/sqlite-backup.nix` and `roles.backup.afterServices`.
- **Scope check:** The plan does not alter flake inputs, package versions, RSS or Calibre modules, database servers, firewall exposure, or the native Readeck service's dynamic-user hardening.
