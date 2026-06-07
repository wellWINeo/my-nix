# Stable Service UIDs/GIDs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move stable UID/GID pinnings out of `machines/mokosh/service-ids.nix` into the role modules that own each service, and add a build-time assertion that fails `nixos-rebuild` on any duplicate UID/GID.

**Architecture:** Each role module sets `users.users.<name>.uid` / `users.groups.<name>.gid` inside its existing `config = mkIf cfg.enable { … }` block. A new module `common/service-id-assertions.nix`, imported via `roles/default.nix`, walks `config.users.users` and `config.users.groups` and emits `assertions` entries listing any duplicated IDs. The central registry file is deleted.

**Tech Stack:** Nix, NixOS module system, `nixos-rebuild`.

**Spec:** `docs/superpowers/specs/2026-06-07-stable-service-ids-design.md`

**Working branch:** `feat/stable-service-ids` (already created, spec already committed).

---

## Pre-flight

Confirm you are on `feat/stable-service-ids` and the spec commit is present.

```bash
git rev-parse --abbrev-ref HEAD
# expected: feat/stable-service-ids
git log -1 --format=%s
# expected: docs: spec role-declared stable service UIDs/GIDs
```

The numeric IDs used throughout this plan are taken verbatim from mokosh's
live `/etc/passwd` and `/etc/group` (captured in the spec). Do not change them.

---

## Task 1: Add the assertion module

**Files:**
- Create: `common/service-id-assertions.nix`

- [ ] **Step 1: Create the module file**

Create `common/service-id-assertions.nix` with this exact content:

```nix
{ config, lib, ... }:

let
  inherit (lib) filter mapAttrsToList concatStringsSep;

  collectDupes =
    entries: idField:
    let
      withId = filter (e: e.${idField} != null) entries;
      grouped = lib.groupBy (e: toString e.${idField}) withId;
      dupeGroups = lib.filterAttrs (_: g: builtins.length g > 1) grouped;
    in
    mapAttrsToList (id: g: {
      inherit id;
      names = map (e: e.name) g;
    }) dupeGroups;

  userEntries = mapAttrsToList (n: u: {
    name = n;
    uid = u.uid;
  }) config.users.users;

  groupEntries = mapAttrsToList (n: g: {
    name = n;
    gid = g.gid;
  }) config.users.groups;

  uidDupes = collectDupes userEntries "uid";
  gidDupes = collectDupes groupEntries "gid";

  mkAssertion = field: d: {
    assertion = false;
    message = "Duplicate ${field} ${d.id} assigned to: ${concatStringsSep ", " d.names}";
  };
in
{
  assertions = (map (mkAssertion "UID") uidDupes) ++ (map (mkAssertion "GID") gidDupes);
}
```

- [ ] **Step 2: Commit**

```bash
git add common/service-id-assertions.nix
git commit -m "feat: add service-id duplicate-detection assertion module"
```

---

## Task 2: Wire the assertion module into roles

**Files:**
- Modify: `roles/default.nix`

- [ ] **Step 1: Replace the imports expression**

Current contents end with:

```nix
in
{
  imports = collectModules ./.;
}
```

Change to:

```nix
in
{
  imports = collectModules ./. ++ [ ../common/service-id-assertions.nix ];
}
```

- [ ] **Step 2: Verify mokosh still evaluates clean**

Run:

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --no-link 2>&1 | tail -30
```

Expected: build succeeds (the assertion module emits no assertions yet because no duplicates exist; existing pinnings in `machines/mokosh/service-ids.nix` are still in effect).

If you see `error: Failed assertions:` listing any "Duplicate UID/GID" message, stop. That means current state already has a collision that the registry was silently masking; report to the user before continuing.

- [ ] **Step 3: Commit**

```bash
git add roles/default.nix
git commit -m "feat: wire service-id assertions into roles"
```

---

## Task 3: Verify the assertion fires on a real conflict

This task introduces a deliberate duplicate, confirms the assertion catches
it, and reverts. No commit.

- [ ] **Step 1: Introduce a deliberate UID collision**

Edit `machines/mokosh/service-ids.nix`: change `vaultwarden` uid from `992` to `993` (which collides with `stalwart-mail`). After editing, the file's first user line should read:

```nix
  users.users.vaultwarden.uid  = 993;
```

- [ ] **Step 2: Build mokosh and confirm the assertion fires**

Run:

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --no-link 2>&1 | tail -20
```

Expected: build fails. Output contains a line of the form:

```
error: Failed assertions:
- Duplicate UID 993 assigned to: stalwart-mail, vaultwarden
```

(Order of names may vary.)

If the build succeeds or the message is different, stop and debug
`common/service-id-assertions.nix` before continuing.

- [ ] **Step 3: Revert the deliberate change**

```bash
git checkout -- machines/mokosh/service-ids.nix
```

- [ ] **Step 4: Confirm clean rebuild**

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --no-link 2>&1 | tail -5
```

Expected: success, no assertion output.

No commit — this task is verification only.

---

## Task 4: Pin nginx UID and web GID in common/server.nix

**Files:**
- Modify: `common/server.nix`

- [ ] **Step 1: Add the UID pin and the GID pin**

In `common/server.nix`, find this block (around line 48):

```nix
  users.groups.web = {
    members =
      optional config.services.nginx.enable "nginx"
      ++ optional (config.security.acme.certs != { }) "acme";
  };
```

Replace it with:

```nix
  users.users.nginx.uid = mkIf config.services.nginx.enable 60;

  users.groups.web = {
    gid = 995;
    members =
      optional config.services.nginx.enable "nginx"
      ++ optional (config.security.acme.certs != { }) "acme";
  };
```

`mkIf` is already in scope via the file's `with lib;` line. Wrapping the UID
in `mkIf config.services.nginx.enable` matches the conditional pattern
already used for `members` and prevents creating a stub `nginx` user on
machines that don't enable nginx. The `web` group is declared unconditionally
in this file, so its `gid` pin is unconditional too.

- [ ] **Step 2: Verify mokosh still evaluates clean**

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --no-link 2>&1 | tail -10
```

Expected: build succeeds, no assertion output.

- [ ] **Step 3: Commit**

```bash
git add common/server.nix
git commit -m "feat(server): pin nginx UID and web GID"
```

---

## Task 5: Pin acme UID/GID in letsencrypt role

**Files:**
- Modify: `roles/letsencrypt.nix`

- [ ] **Step 1: Add the pins inside the config block**

In `roles/letsencrypt.nix`, the `config = mkIf cfg.enable { ... };` block currently contains only `security.acme = { ... };`. Add UID/GID pins above the `security.acme` assignment so the block becomes:

```nix
  config = mkIf cfg.enable {
    users.users.acme.uid = 996;
    users.groups.acme.gid = 994;

    security.acme = {
      acceptTerms = true;
      defaults = {
        email = "stepan@${firstDomain}";
        group = "web";
      };

      certs = listToAttrs (
        map (domain: {
          name = domain;
          value = {
            dnsProvider = "cloudflare";
            environmentFile = "/etc/nixos/secrets/cloudflare.ini";
            domain = domain;
            extraDomainNames = [ "*.${domain}" ];
          };
        }) cfg.domains
      );
    };
  };
```

- [ ] **Step 2: Verify mokosh still evaluates clean**

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --no-link 2>&1 | tail -10
```

Expected: build succeeds, no assertion output.

- [ ] **Step 3: Commit**

```bash
git add roles/letsencrypt.nix
git commit -m "feat(letsencrypt): pin acme UID/GID in role"
```

---

## Task 6: Pin sing-box UID/GID in sing-box server role

**Files:**
- Modify: `roles/network/sing-box/server.nix`

- [ ] **Step 1: Add the pins inside the config block**

In `roles/network/sing-box/server.nix`, find the existing `config = mkIf cfg.enable {` block (around line 128) and its first child `assertions = [ … ];`. Add the user/group pins immediately before the `assertions` line:

```nix
  config = mkIf cfg.enable {
    users.users.sing-box.uid = 994;
    users.groups.sing-box.gid = 992;

    assertions = [
      {
        assertion = cfg.vlessWs.enable || cfg.vlessGrpc.enable || cfg.naive.enable;
        message = "At least one sing-box inbound must be enabled";
      }
    ];
```

(Rest of the block unchanged.)

- [ ] **Step 2: Verify mokosh still evaluates clean**

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --no-link 2>&1 | tail -10
```

Expected: build succeeds, no assertion output.

- [ ] **Step 3: Commit**

```bash
git add roles/network/sing-box/server.nix
git commit -m "feat(sing-box): pin sing-box UID/GID in role"
```

---

## Task 7: Pin vaultwarden UID/GID in vault role

**Files:**
- Modify: `roles/vault.nix`

- [ ] **Step 1: Add the pins inside the config block**

In `roles/vault.nix`, the `config = mkIf cfg.enable (mkMerge [ ... ]);` expression has a second mkMerge child starting with `{ roles.backup.paths = [ backupDir ]; … }`. Add the pins as the first two attributes of that child block:

```nix
    {
      users.users.vaultwarden.uid = 992;
      users.groups.vaultwarden.gid = 990;

      roles.backup.paths = [ backupDir ];

      services.vaultwarden = {
        # … unchanged …
```

- [ ] **Step 2: Verify mokosh still evaluates clean**

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --no-link 2>&1 | tail -10
```

Expected: build succeeds, no assertion output.

- [ ] **Step 3: Commit**

```bash
git add roles/vault.nix
git commit -m "feat(vault): pin vaultwarden UID/GID in role"
```

---

## Task 8: Pin stalwart-mail UID/GID in mail role

**Files:**
- Modify: `roles/communication/mail.nix`

- [ ] **Step 1: Add the pins next to the existing users.users.stalwart-mail entry**

In `roles/communication/mail.nix`, find the existing line (around line 201):

```nix
    users.users.stalwart-mail.extraGroups = [ "web" ];
```

Add the UID and GID pins immediately above it:

```nix
    users.users.stalwart-mail.uid = 993;
    users.groups.stalwart-mail.gid = 991;
    users.users.stalwart-mail.extraGroups = [ "web" ];
```

- [ ] **Step 2: Verify mokosh still evaluates clean**

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --no-link 2>&1 | tail -10
```

Expected: build succeeds, no assertion output.

- [ ] **Step 3: Commit**

```bash
git add roles/communication/mail.nix
git commit -m "feat(mail): pin stalwart-mail UID/GID in role"
```

---

## Task 9: Pin writefreely UID/GID in blog role

**Files:**
- Modify: `roles/blog.nix`

- [ ] **Step 1: Add the pins inside the second mkMerge child**

In `roles/blog.nix`, the `config = mkIf cfg.enable (mkMerge [ ... ]);` has a second child block starting with `{ roles.backup.paths = [ "/var/backup/writefreely" ]; … }`. Add the pins as the first two attributes of that child:

```nix
    {
      users.users.writefreely.uid = 991;
      users.groups.writefreely.gid = 989;

      roles.backup.paths = [ "/var/backup/writefreely" ];
      roles.backup.afterServices = [ "backup-writefreely.service" ];

      services.writefreely = {
        # … unchanged …
```

- [ ] **Step 2: Verify mokosh still evaluates clean**

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --no-link 2>&1 | tail -10
```

Expected: build succeeds, no assertion output.

- [ ] **Step 3: Commit**

```bash
git add roles/blog.nix
git commit -m "feat(blog): pin writefreely UID/GID in role"
```

---

## Task 10: Pin calibre-web UID and calibre GID in calibre role

**Files:**
- Modify: `roles/reading/calibre.nix`

- [ ] **Step 1: Replace the calibre group declaration and add the user pin**

In `roles/reading/calibre.nix`, find this line (around line 43):

```nix
      users.groups.calibre = { };
```

Replace it with:

```nix
      users.users.calibre-web.uid = 995;
      users.groups.calibre.gid = 993;
```

- [ ] **Step 2: Verify mokosh still evaluates clean**

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --no-link 2>&1 | tail -10
```

Expected: build succeeds, no assertion output.

- [ ] **Step 3: Commit**

```bash
git add roles/reading/calibre.nix
git commit -m "feat(calibre): pin calibre-web UID and calibre GID in role"
```

---

## Task 11: Pin postgres UID/GID in rss/miniflux role

**Files:**
- Modify: `roles/reading/rss/miniflux.nix`

- [ ] **Step 1: Add the pins inside the config block**

In `roles/reading/rss/miniflux.nix`, find the `config = mkIf cfg.enable { ... };` block (line 22). Add the pins as the first two attributes inside it:

```nix
  config = mkIf cfg.enable {
    users.users.postgres.uid = 71;
    users.groups.postgres.gid = 71;

    services.miniflux = {
      # … unchanged …
```

- [ ] **Step 2: Verify mokosh still evaluates clean**

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --no-link 2>&1 | tail -10
```

Expected: build succeeds, no assertion output.

- [ ] **Step 3: Commit**

```bash
git add roles/reading/rss/miniflux.nix
git commit -m "feat(rss): pin postgres UID/GID in role"
```

---

## Task 12: Remove the central registry

**Files:**
- Delete: `machines/mokosh/service-ids.nix`
- Modify: `machines/mokosh/default.nix`

- [ ] **Step 1: Drop the registry import from mokosh's default.nix**

In `machines/mokosh/default.nix`, the `imports = [ … ];` list contains the line:

```nix
    ./service-ids.nix
```

Remove that line. The surrounding imports should look like:

```nix
  imports = [
    ../../common/cache.nix
    ../../common/hardened.nix
    ../../common/server.nix
    ../../images/do-generic
    ../../roles
  ];
```

- [ ] **Step 2: Delete the registry file**

```bash
git rm machines/mokosh/service-ids.nix
```

- [ ] **Step 3: Verify mokosh still evaluates clean**

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --no-link 2>&1 | tail -10
```

Expected: build succeeds, no assertion output. All previously-pinned IDs are
now sourced from the role files.

- [ ] **Step 4: Commit**

```bash
git add machines/mokosh/default.nix
git commit -m "refactor(mokosh): drop centralized service-ids registry"
```

---

## Task 13: Cross-machine verification

This task confirms that pinning IDs in shared role files and `common/server.nix`
has not broken any other machine's evaluation.

- [ ] **Step 1: Build every machine**

Run each in turn. Each must succeed.

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --no-link 2>&1 | tail -5
nix build .#nixosConfigurations.buyan.config.system.build.toplevel  --no-link 2>&1 | tail -5
nix build .#nixosConfigurations.veles.config.system.build.toplevel  --no-link 2>&1 | tail -5
nix build .#nixosConfigurations.nixpi.config.system.build.toplevel  --no-link 2>&1 | tail -5
```

Expected: all four succeed with no `Failed assertions` output.

If any machine fails with a `Duplicate UID/GID` assertion, the assertion is
doing its job — that machine has an existing user/group that collides with
one of the pinned numbers. Report which assertion fired to the user; do not
silently change pinned numbers.

If a machine fails for another reason (unrelated eval error), report it; the
fault is pre-existing and outside the scope of this plan.

- [ ] **Step 2: Final git log sanity check**

```bash
git log --oneline main..HEAD
```

Expected commits, in order:

1. `docs: spec role-declared stable service UIDs/GIDs`
2. `feat: add service-id duplicate-detection assertion module`
3. `feat: wire service-id assertions into roles`
4. `feat(server): pin nginx UID and web GID`
5. `feat(letsencrypt): pin acme UID/GID in role`
6. `feat(sing-box): pin sing-box UID/GID in role`
7. `feat(vault): pin vaultwarden UID/GID in role`
8. `feat(mail): pin stalwart-mail UID/GID in role`
9. `feat(blog): pin writefreely UID/GID in role`
10. `feat(calibre): pin calibre-web UID and calibre GID in role`
11. `feat(rss): pin postgres UID/GID in role`
12. `refactor(mokosh): drop centralized service-ids registry`

No commit for this task.

---

## Deployment (out of plan scope)

Deploying to mokosh is the user's call. Because every pinned UID/GID matches
the live `/etc/passwd` and `/etc/group` on the host, the deploy is expected
to be a no-op for user/group state. No `chown` operations, no service
restarts triggered by ID change. Any unrelated service restarts come from
the standard NixOS rebuild diff.

The user will open a PR and deploy from `main` after merge.
