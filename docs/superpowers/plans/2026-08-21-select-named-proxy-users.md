# Select Named Proxy Users Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Select proxy credentials by explicit `singBoxUsers.name` for nixpi-to-Veles and Veles-to-Buyan authentication instead of list order.

**Architecture:** Add a shared selector that returns exactly one user matching a requested name and throws a clear evaluation error otherwise. Nixpi selects the `nixpi` entry; Veles selects the `veles` entry for its relay target. Existing `hosts` filtering remains responsible for inbound authorization.

**Tech Stack:** NixOS modules, Nix, JSON dummy secrets, jq.

## Global Constraints

- Match `singBoxUsers` entries by exact `name`.
- Missing or duplicate names must fail evaluation clearly.
- Keep hostname-based `hosts` filtering unchanged.
- Do not expose or add real secret material.
- Format changed Nix files with `nixfmt`.

---

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `common/select-proxy-user.nix` | Create | Select exactly one named proxy user. |
| `machines/nixpi/default.nix` | Modify | Use the `nixpi` user for Veles client authentication. |
| `machines/veles/default.nix` | Modify | Use the `veles` user for Buyan relay authentication. |
| `secrets/secrets.dummy.json` | Modify | Provide named dummy users needed by all evaluated configurations. |

### Task 1: Add the exact-name proxy-user selector

**Files:**
- Create: `common/select-proxy-user.nix`

**Interface:**
- Input: `hostname :: str`, `users :: list of attrsets`.
- Output: exactly one user attrset whose `name` equals `hostname`.
- Failure: evaluation error stating the requested name and match count.

- [ ] **Step 1: Write the selector**

Create `common/select-proxy-user.nix`:

```nix
hostname: users:
let
  matches = builtins.filter (u: (u.name or "") == hostname) users;
  count = builtins.length matches;
in
if count == 1 then
  builtins.head matches
else
  throw "Expected exactly one singBoxUsers entry named '${hostname}', found ${builtins.toString count}";
```

- [ ] **Step 2: Verify one, zero, and duplicate matches**

Run:

```bash
nix eval --impure --expr '
  let select = import ./common/select-proxy-user.nix;
  in (select "nixpi" [{ name = "nixpi"; uuid = "one"; }]).uuid
'

if nix eval --impure --expr '
  let select = import ./common/select-proxy-user.nix;
  in select "nixpi" [{ name = "veles"; uuid = "one"; }]
' 2>/tmp/select-missing.err; then
  echo "missing-user test unexpectedly passed" >&2
  exit 1
fi
grep -F "named 'nixpi', found 0" /tmp/select-missing.err

if nix eval --impure --expr '
  let select = import ./common/select-proxy-user.nix;
  in select "nixpi" [{ name = "nixpi"; uuid = "one"; } { name = "nixpi"; uuid = "two"; }]
' 2>/tmp/select-duplicate.err; then
  echo "duplicate-user test unexpectedly passed" >&2
  exit 1
fi
grep -F "named 'nixpi', found 2" /tmp/select-duplicate.err
```

Expected: the first command prints `"one"`; the two negative cases fail with the requested name and count.

- [ ] **Step 3: Format and inspect the helper**

Run:

```bash
nixfmt common/select-proxy-user.nix
git diff --check
```

- [ ] **Step 4: Commit the selector**

```bash
git add common/select-proxy-user.nix
git commit -m "feat(proxy): select users by name"
```

### Task 2: Use named credentials in machine configurations

**Files:**
- Modify: `machines/nixpi/default.nix`
- Modify: `machines/veles/default.nix`

**Interfaces:**
- Nixpi consumes `selectProxyUser` and produces `nixpiXrayUser` from the `nixpi` entry.
- Veles consumes `selectProxyUser` and produces `relayUser` from the `veles` entry.
- Existing `filterProxyUsersForHost` bindings remain unchanged.

- [ ] **Step 1: Switch nixpi from host-filtered selection to the named entry**

In `machines/nixpi/default.nix`, add the helper binding and replace the current user binding:

```nix
  selectProxyUser = import ../../common/select-proxy-user.nix;
  nixpiXrayUser = selectProxyUser hostname secrets.singBoxUsers;
```

The resulting local bindings must retain `filterProxyUsersForHost` only if it is otherwise used; this file should not retain an unused host-filter helper.

- [ ] **Step 2: Switch Veles relay target credentials to the named entry**

In `machines/veles/default.nix`, add:

```nix
  selectProxyUser = import ../../common/select-proxy-user.nix;
  relayUser = selectProxyUser hostname secrets.singBoxUsers;
```

Replace:

```nix
      user = builtins.head secrets.singBoxUsers;
```

with:

```nix
      user = relayUser;
```

Keep `users = filterProxyUsersForHost hostname secrets.singBoxUsers;` unchanged for Veles inbound authorization.

- [ ] **Step 3: Format the machine files**

```bash
nixfmt machines/nixpi/default.nix machines/veles/default.nix
git diff --check
```

- [ ] **Step 4: Commit machine wiring**

```bash
git add machines/nixpi/default.nix machines/veles/default.nix
git commit -m "fix(proxy): use named users for relay authentication"
```

### Task 3: Make dummy secrets represent named users and validate configurations

**Files:**
- Modify: `secrets/secrets.dummy.json`

- [ ] **Step 1: Add named dummy users without removing the existing wildcard user**

Keep the existing `dummy` entry and add unique `nixpi` and `veles` entries to `singBoxUsers`:

```json
    {
      "uuid": "00000000-0000-0000-0000-000000000001",
      "name": "nixpi",
      "password": "dummypassword-nixpi",
      "hosts": ["veles"]
    },
    {
      "uuid": "00000000-0000-0000-0000-000000000002",
      "name": "veles",
      "password": "dummypassword-veles",
      "hosts": ["veles", "buyan"]
    }
```

The `veles` dummy user must be accepted by Buyan, while the `nixpi` dummy user must be accepted by Veles.

- [ ] **Step 2: Validate JSON and rendered user selection**

```bash
jq empty secrets/secrets.dummy.json
make setup-dummy-secrets
nix eval --json 'path:.#nixosConfigurations.nixpi.config.services.xray.settings' >/tmp/nixpi-xray.json
nix eval --json 'path:.#nixosConfigurations.veles.config.roles.xray.relay.user' | jq -e '.name == "veles"'
nix eval --json 'path:.#nixosConfigurations.nixpi.config.roles.xray.client.vlessTcp.auth' | jq -e '.name == "nixpi"'
```

Expected: all commands succeed and the two final checks return true.

- [ ] **Step 3: Run repository validation**

```bash
nixfmt --check common/select-proxy-user.nix machines/nixpi/default.nix machines/veles/default.nix
git diff --check
nix build 'path:.#nixosConfigurations.nixpi.config.system.build.toplevel' --dry-run
make check
```

Expected: all commands exit successfully.

- [ ] **Step 4: Review the final diff and status**

```bash
git diff origin/main...HEAD -- common/select-proxy-user.nix machines/nixpi/default.nix machines/veles/default.nix secrets/secrets.dummy.json
 git status --short
```

Expected: only the selector, named-user wiring, and dummy-user changes are present; no secret file is staged.
