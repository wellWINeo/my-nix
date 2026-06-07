# Stable service UIDs/GIDs declared by roles

## Problem

Service users and groups on `mokosh` are currently pinned in a single registry
file, `machines/mokosh/service-ids.nix`. The host restores file-owned state
from restic backups, so on-disk inode ownership must match the UIDs/GIDs the
NixOS configuration synthesizes; if a service ever gets a different
auto-allocated UID after a reinstall, the restore breaks.

The single-registry approach works, but:

- Roles no longer own their own IDs — the registry lives at the machine layer,
  divorced from the role definition that creates the service user.
- Roles cannot be safely reused on other machines with the same restore
  guarantee without copy-pasting registry entries.
- Live state on mokosh has drifted past what the registry captures: `nginx`,
  `acme`, `sing-box`, and `calibre-web` are at fixed numbers in `/etc/passwd`
  but are not pinned in Nix, so a reinstall could re-allocate them.

## Goals

- Every service whose on-disk files survive a reinstall has its UID/GID
  declared in the role module that owns the service.
- A duplicate UID or GID anywhere in the evaluated configuration fails the
  build with a clear message naming the colliders.
- No central registry file. No reserved per-role number ranges.
- Pinned values match what is currently live on mokosh, so the migration
  rebuild is a no-op for `/etc/passwd`.

## Non-goals

- Pinning human user accounts (e.g. `o__ni`). Out of scope.
- Pinning upstream-stable identities (`root`, `nobody`, `messagebus`, `sshd`,
  `nscd`, `systemd-*`, `nixbld*`). NixOS sets these to fixed low numbers.
- Pinning DynamicUser services (e.g. `miniflux`). systemd manages their IDs
  outside `/etc/passwd`.
- Reconciling drift between Nix config and on-disk ownership on hosts whose
  `/etc/passwd` already exists. That is a state question, not a config one.

## Architecture

Each role module that creates a service user or group pins its own UID/GID
inside its existing `config = mkIf cfg.enable { … }` block, alongside the rest
of that role's NixOS configuration. There is no central registry.

A new module, `common/service-id-assertions.nix`, runs unconditionally on any
machine that imports roles. It:

1. Walks `config.users.users`, collecting `(name, uid)` pairs where `uid` is
   not null.
2. Walks `config.users.groups`, collecting `(name, gid)` pairs where `gid` is
   not null.
3. For any UID (or GID) shared by two or more names, emits one entry in
   `assertions` listing the offending names and the duplicated number.

A duplicate causes `nixos-rebuild` to fail at evaluation with output like:

    error: Failed assertions:
    - Duplicate UID 992 assigned to: vaultwarden, stalwart-mail

The assertion module is imported by `roles/default.nix`, so it activates on
every machine that consumes roles — no per-machine wiring.

## Components

### New file: `common/service-id-assertions.nix`

```nix
{ config, lib, ... }:

let
  inherit (lib) filter mapAttrsToList concatStringsSep;

  collectDupes = entries: idField:
    let
      withId = filter (e: e.${idField} != null) entries;
      grouped = lib.groupBy (e: toString e.${idField}) withId;
      dupeGroups = lib.filterAttrs (_: g: builtins.length g > 1) grouped;
    in
      mapAttrsToList (id: g: {
        inherit id;
        names = map (e: e.name) g;
      }) dupeGroups;

  userEntries  = mapAttrsToList (n: u: { name = n; uid = u.uid; }) config.users.users;
  groupEntries = mapAttrsToList (n: g: { name = n; gid = g.gid; }) config.users.groups;

  uidDupes = collectDupes userEntries  "uid";
  gidDupes = collectDupes groupEntries "gid";

  mkAssertion = field: d: {
    assertion = false;
    message = "Duplicate ${field} ${d.id} assigned to: ${concatStringsSep ", " d.names}";
  };
in
{
  assertions =
    (map (mkAssertion "UID") uidDupes) ++
    (map (mkAssertion "GID") gidDupes);
}
```

Properties:

- Pure attrset reduction; no side effects.
- Triggers at evaluation time, before activation.
- One assertion per duplicate ID, listing every colliding name — a real
  conflict surfaces all offenders in one rebuild.
- `null` UIDs/GIDs (unpinned services) are ignored.

### Pinning placements

UID/GID values reflect what is currently live on mokosh:

| File                                | Pinning                                                                |
|-------------------------------------|------------------------------------------------------------------------|
| `common/server.nix`                 | `users.users.nginx.uid = 60`, `users.groups.web.gid = 995`             |
| `roles/letsencrypt.nix`             | `users.users.acme.uid = 996`, `users.groups.acme.gid = 994`            |
| `roles/network/sing-box/server.nix` | `users.users.sing-box.uid = 994`, `users.groups.sing-box.gid = 992`    |
| `roles/vault.nix`                   | `users.users.vaultwarden.uid = 992`, `users.groups.vaultwarden.gid = 990` |
| `roles/communication/mail.nix`      | `users.users.stalwart-mail.uid = 993`, `users.groups.stalwart-mail.gid = 991` |
| `roles/blog.nix`                    | `users.users.writefreely.uid = 991`, `users.groups.writefreely.gid = 989` |
| `roles/reading/calibre.nix`         | `users.users.calibre-web.uid = 995`, `users.groups.calibre.gid = 993`  |
| `roles/reading/rss/miniflux.nix`    | `users.users.postgres.uid = 71`, `users.groups.postgres.gid = 71`      |

Each pinning lives inside its role's existing `config = mkIf cfg.enable { … }`
block as a plain assignment (no `mkDefault` — these are hard pins).

### Wiring

`roles/default.nix` currently sets `imports = collectModules ./.;`. It changes
to:

```nix
imports = collectModules ./. ++ [ ../common/service-id-assertions.nix ];
```

so the assertion module loads whenever roles do.

### Deletions

- `machines/mokosh/service-ids.nix` — content has migrated into roles.
- The `./service-ids.nix` entry in `machines/mokosh/default.nix`'s `imports`.

## Cross-machine consequences

`common/server.nix` is imported by every server machine, so pinning `nginx`
and `web` there pins them on `buyan` and `veles` as well. This is intentional
and harmless: NixOS already allocates `nginx` to uid 60 by default on fresh
installs, and any divergence on an existing host surfaces as the same
assertion-style rebuild failure, which is the correct moment to discover and
resolve it.

Role-level pins (vault, mail, blog, calibre, rss, sing-box) apply only on
machines that enable those roles, because they sit inside `mkIf cfg.enable`.

## Error handling

The assertion module catches:

- Two roles assigning the same UID or GID.
- A typo'd duplicate within one role.
- A future case where an unpinned upstream user collides with a pinned
  in-tree number.

It does not catch:

- Drift between Nix config and on-disk inode ownership on an existing host
  (out of scope; see Non-goals).
- DynamicUser identities (managed by systemd, not in `/etc/passwd`).

## Testing

- `nixos-rebuild build --flake .#mokosh` must succeed unchanged.
- `nixos-rebuild build --flake .#buyan`, `.#veles`, and `.#nixpi` must each
  succeed, flushing out any cross-machine conflict before deploy.
- One deliberate-failure check during review: temporarily set two users to
  the same UID, confirm the assertion fires with the expected message,
  revert.

## Migration

Single PR, single rebuild on mokosh:

1. Add `common/service-id-assertions.nix`.
2. Wire it into `roles/default.nix`.
3. Add the eight pin blocks listed above to their respective files.
4. Delete `machines/mokosh/service-ids.nix` and its import in
   `machines/mokosh/default.nix`.
5. `nixos-rebuild build --flake .#mokosh` — verify clean eval.
6. Deploy.

Because every pinned number matches live state, the deploy is a no-op for
`/etc/passwd`: no UID changes, no `chown` storm, no service restarts beyond
what unrelated config changes already trigger.

## Rollback

Config-only change. `git revert` plus a rebuild restores the prior layout.
No data migration to undo.
