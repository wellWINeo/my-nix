# Readeck on Mokosh

**Status:** approved
**Date:** 2026-08-02

## Goal

Deploy Readeck on `mokosh` as the reading service at
`readlater.uspenskiy.tech`. Readeck will use the native NixOS module, a local
SQLite database, persistent local application state, and the existing Nginx
and restic infrastructure.

The first application account will be created once after deployment with the
Readeck CLI. Account creation is application data and will not be managed by
Nix.

## Scope

- Add a standalone `roles.readeck` role under `roles/reading/readeck.nix`.
- Enable the role on `mokosh` with `domainNames.secondary` as its base domain.
- Use the pinned nixpkgs `services.readeck` module and package.
- Bind Readeck to `127.0.0.1:8000`.
- Publish it through the existing Nginx setup as `readlater.uspenskiy.tech`.
- Configure SQLite at `/var/lib/readeck/db.sqlite3`.
- Keep Readeck state under `/var/lib/readeck`.
- Load a stable `READECK_SECRET_KEY` from an encrypted environment file.
- Back up the SQLite database and Readeck state through the existing backup
  role.
- Document one-time post-deployment account creation.

## Non-Goals

- No Wallabag deployment or compatibility layer.
- No PostgreSQL database.
- No container runtime or custom Readeck derivation.
- No custom systemd bootstrap service for the initial account.
- No separate public port, firewall rule, or certificate request.
- No new flake input or lockfile change.
- No automated test framework.

## Decisions

### Native NixOS Service

Use the existing nixpkgs `services.readeck` module rather than recreating the
service around `pkgs.readeck`. The module provides the pinned package,
`StateDirectory = "readeck"`, a dynamic service user, systemd hardening, and
restart-on-failure behavior.

The pinned nixpkgs source currently provides Readeck `0.22.3`. The default
package selected by the module will be used; no package override is needed.

### Role Placement

Create `roles/reading/readeck.nix`. The repository's recursive role loader
already imports regular Nix files below `roles/`, so no additional reading
directory import is required.

The module will declare:

```nix
options.roles.readeck = {
  enable = mkEnableOption "Readeck";
  baseDomain = mkOption {
    type = types.str;
    description = "2nd level domain name (base)";
  };
};
```

`machines/mokosh/default.nix` will enable it as:

```nix
roles.readeck = {
  enable = true;
  baseDomain = domainNames.secondary;
};
```

This resolves the public hostname to `readlater.uspenskiy.tech`.

### Readeck Configuration

The role will set the native module's `settings` values to:

```nix
settings = {
  main.data_directory = "/var/lib/readeck";
  server = {
    host = "127.0.0.1";
    port = 8000;
    allowed_hosts = [ "readlater.uspenskiy.tech" ];
    trusted_proxies = [ "127.0.0.1" ];
    base_url = "https://readlater.uspenskiy.tech";
  };
  database.source = "sqlite3:/var/lib/readeck/db.sqlite3";
};
```

The secret key will not be placed in this generated TOML. The role will set:

```nix
environmentFile = "/etc/nixos/secrets/readeck.env";
```

The encrypted file will contain `READECK_SECRET_KEY`, which Readeck supports
as an environment-based secret override.

### Nginx Exposure

The role will add an Nginx virtual host for `readlater.uspenskiy.tech` with:

- `forceSSL = true`;
- the existing certificate and key under `/var/lib/acme/uspenskiy.tech/`;
- proxying to `http://127.0.0.1:8000`;
- the repository's recommended proxy settings;
- `client_max_body_size 50M`;
- proxy buffering disabled, matching Readeck's deployment guidance.

The existing wildcard certificate for `uspenskiy.tech` covers the hostname.
Port `8000` will not be added to `networking.firewall.allowedTCPPorts`.

### Secret Provisioning

Add a `mokosh:readeck.env:0400:root:root` entry to the encrypted secrets file
specification. The deployed file will be `/etc/nixos/secrets/readeck.env` and
will contain only the stable Readeck secret key.

The secret must remain stable across restarts, rebuilds, and upgrades because
it protects sessions and other application data. No secret value belongs in
the repository, `secrets.json`, generated Nix configuration, or the design and
implementation documents.

### SQLite and Backups

Reuse `common/sqlite-backup.nix` with:

- database: `/var/lib/readeck/db.sqlite3`;
- backup directory: `/var/backup/readeck`;
- backup user and group: `root`;
- extra path: `/var/lib/readeck/`.

The root backup service is intentional: the native Readeck unit uses a
dynamic systemd user, so there is no stable service account to use for the
backup helper. The SQLite snapshot provides a consistent database copy, while
the additional state copy preserves saved content and application files.

The role will add `/var/backup/readeck` to `roles.backup.paths` and add
`backup-readeck.service` to `roles.backup.afterServices`. This makes the
restic backup run after the SQLite snapshot and disables the helper's
standalone timer through the existing backup-role mechanism.

### Initial Account

The role will not create a declarative initial user. After the first
successful deployment, the operator will invoke the native `readeck user`
command once, using the generated Readeck configuration and
`/etc/nixos/secrets/readeck.env`. The password will be supplied interactively
or through the command's supported environment-variable form.

The implementation plan will document the exact command sequence for locating
the generated configuration and running the CLI through a transient root
command. No application password will be added to Nix or the repository.

## Data Flow

```text
Client
  |
  | HTTPS readlater.uspenskiy.tech
  v
Nginx :443
  |
  | HTTP loopback
  v
Readeck :8000
  |
  +-- SQLite /var/lib/readeck/db.sqlite3
  +-- Saved content /var/lib/readeck

backup-readeck.service
  |
  v
/var/backup/readeck
  |
  v
roles.backup / restic
```

## Failure Handling

- The native Readeck unit restarts after process failure.
- A missing or invalid environment file fails the service explicitly rather
  than causing a new secret to be generated.
- Readeck remains inaccessible from the network except through Nginx and HTTPS.
- SQLite is local-only and is not placed on a network filesystem.
- The restic backup is ordered after the SQLite snapshot attempt; a failed
  snapshot remains visible as a failed systemd unit and must be investigated
  before treating the corresponding restic backup as complete.
- Readeck application errors remain visible through the system journal and
  HTTP responses; Nginx remains responsible only for proxying and TLS.

## Verification

Repository validation will cover:

1. Formatting all changed Nix files with `nixfmt`.
2. Evaluating `nixosConfigurations.mokosh` with dummy secrets when real secrets
   are unavailable.
3. Confirming that `roles.readeck.enable` produces the expected native service
   settings, SQLite source, secret-file path, Nginx hostname, and backup unit.
4. Confirming that port `8000` is absent from the firewall configuration.
5. Running `make check`.
6. Confirming on `mokosh` that `readeck.service` is active.
7. Confirming that Readeck responds on loopback and through
   `https://readlater.uspenskiy.tech`.
8. Confirming that port `8000` is bound to `127.0.0.1` only.
9. Creating the first account with the documented one-time CLI command and
   verifying a successful login.
10. Running `backup-readeck.service` and confirming that the SQLite snapshot and
    state copy are readable by the restic backup service.
11. Running `git diff --check` and reviewing the final file scope.

The implementation will not add an automated test framework. Nix evaluation,
flake checks, and deployment smoke tests match the repository's current
validation model.

## Expected File Changes

- `roles/reading/readeck.nix`: declare the role and configure Readeck, Nginx,
  SQLite backup, and restic ordering.
- `machines/mokosh/default.nix`: enable Readeck with `uspenskiy.tech` as the
  base domain.
- `README.md`: list Readeck under the reading roles and document its public
  hostname and local service boundary.
- `secrets/unlocked/spec.txt`: declare the encrypted Readeck environment file.
- `docs/superpowers/specs/2026-08-02-readeck-mokosh-design.md`: record this
  approved design.
- `docs/superpowers/plans/2026-08-02-readeck-mokosh.md`: implementation plan
  created after this spec is reviewed.

No changes are planned for `flake.nix`, `flake.lock`, `common/sqlite-backup.nix`,
or the existing RSS and Calibre modules.

## Alternatives Considered

### Custom Static-User Service

A custom service around `pkgs.readeck` would provide a fixed account for
backups, but it would duplicate the native module and its hardening settings.
Running the backup helper as root avoids that duplication while preserving the
native service boundary.

### Containerized Readeck

The upstream container would track Readeck releases directly, but containers
are not part of the repository's current service model. It would add a runtime,
image lifecycle, and a separate storage model without solving a current need.

### PostgreSQL

PostgreSQL is already present for Miniflux, but Readeck explicitly supports
SQLite for a single-instance deployment. Local SQLite keeps this service
isolated and avoids another database schema, credentials, and backup path.
