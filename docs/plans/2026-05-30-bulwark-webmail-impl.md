# Bulwark Webmail Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Package Bulwark Webmail from source and deploy it as a NixOS role alongside the existing Stalwart mail server on mokosh.

**Architecture:** Three files: a Nix derivation in `pkgs/bulwark-webmail/default.nix` that builds the Next.js standalone output; a NixOS role module in `roles/webmail.nix` with systemd service and nginx vhost; and minor wiring in the mokosh machine config + flake overlay.

**Tech Stack:** Nix, buildNpmPackage, Node.js 24, Next.js 16 standalone, systemd, nginx

---

### Task 1: Create the package derivation

**Files:**
- Create: `pkgs/bulwark-webmail/default.nix`

**Step 1: Create the package directory**

```bash
mkdir -p pkgs/bulwark-webmail
```

**Step 2: Write the derivation**

Create `pkgs/bulwark-webmail/default.nix`:

```nix
{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  nodejs_24,
}:

buildNpmPackage (finalAttrs: {
  pname = "bulwark-webmail";
  version = "1.7.2";

  src = fetchFromGitHub {
    owner = "bulwarkmail";
    repo = "webmail";
    tag = "v${finalAttrs.version}";
    hash = "sha256-PLACEHOLDER";
  };

  npmDepsHash = "sha256-PLACEHOLDER";

  nodejs = nodejs_24;

  npmBuildScript = "build";

  env = {
    NEXT_TELEMETRY_DISABLED = "1";
    GIT_COMMIT = "unknown";
  };

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r .next/standalone/. $out/
    cp -r .next/static $out/.next/static
    cp -r public $out/public

    runHook postInstall
  '';

  meta = {
    description = "Modern webmail client for Stalwart Mail Server, built with Next.js and JMAP";
    homepage = "https://github.com/bulwarkmail/webmail";
    license = lib.licenses.agpl3Only;
    mainProgram = "server";
  };
})
```

**Step 3: Get the actual source hash**

```bash
nix-prefetch-url --unpack https://github.com/bulwarkmail/webmail/archive/refs/tags/v1.7.2.tar.gz
```

Update `hash` in the derivation with the output.

**Step 4: Get the npm deps hash**

```bash
cd /tmp && git clone --depth 1 --branch v1.7.2 https://github.com/bulwarkmail/webmail.git bulwark-hash && cd bulwark-hash && prefetch-npm-deps package-lock.json
```

Update `npmDepsHash` in the derivation with the output.

**Step 5: Test the build**

```bash
nix build path:.#legacyPackages.x86_64-linux.bulwark-webmail
```

Expected: successful build producing the standalone Next.js server.

**Step 6: Commit**

```bash
git add pkgs/bulwark-webmail/default.nix
git commit -m "feat: add bulwark-webmail package derivation"
```

---

### Task 2: Add the overlay

**Files:**
- Modify: `overlays/default.nix`

**Step 1: Add bulwark-webmail to the global overlay**

The overlay file currently only overrides `n8n`. Add the bulwark-webmail package:

```nix
[
  (final: prev: {
    n8n = prev.n8n.overrideAttrs (oldAttrs: {
      NODE_OPTIONS = "--max-old-space-size=4096";
    });

    bulwark-webmail = prev.callPackage ../pkgs/bulwark-webmail { };
  })
]
```

**Step 2: Verify overlay evaluates**

```bash
nix eval path:.#legacyPackages.x86_64-linux.bulwark-webmail.meta.description
```

Expected: the description string.

**Step 3: Commit**

```bash
git add overlays/default.nix
git commit -m "feat: add bulwark-webmail overlay"
```

---

### Task 3: Create the webmail NixOS role

**Files:**
- Create: `roles/webmail.nix`

**Step 1: Write the role module**

Create `roles/webmail.nix`:

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.webmail;
  port = cfg.port;
  dataDir = "/var/lib/bulwark-webmail";
  webmailHostname = "webmail.${cfg.baseDomain}";
in
{
  options.roles.webmail = {
    enable = mkEnableOption "Enable Bulwark webmail client";

    baseDomain = mkOption {
      type = types.str;
      description = "Base domain for SSL certs and hostname derivation";
    };

    port = mkOption {
      type = types.int;
      default = 11080;
      description = "Internal port for the webmail service";
    };

    jmapServerUrl = mkOption {
      type = types.str;
      description = "JMAP server URL to connect to";
    };

    sessionSecretFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File containing the session secret for encrypting sessions";
    };

    stalwartFeatures = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Stalwart-specific features (password change, sieve filters)";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.bulwark-webmail = {
      description = "Bulwark Webmail";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        HOSTNAME = "127.0.0.1";
        PORT = toString port;
        NODE_ENV = "production";
        NEXT_TELEMETRY_DISABLED = "1";
        JMAP_SERVER_URL = cfg.jmapServerUrl;
        STALWART_FEATURES = if cfg.stalwartFeatures then "true" else "false";
        SETTINGS_SYNC_ENABLED = "true";
        SETTINGS_DATA_DIR = "${dataDir}/data/settings";
        ADMIN_CONFIG_DIR = "${dataDir}/data/admin";
        ADMIN_STATE_DIR = "${dataDir}/data/admin-state";
        TELEMETRY_DATA_DIR = "${dataDir}/data/telemetry";
      } // optionalAttrs (cfg.sessionSecretFile != null) {
        SESSION_SECRET_FILE = cfg.sessionSecretFile;
      };

      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "bulwark-webmail";
        WorkingDirectory = dataDir;
        ExecStart = "${pkgs.nodejs_24}/bin/node ${pkgs.bulwark-webmail}/server.js";
        Restart = "on-failure";
        RestartSec = "5";

        ExecStartPre = [
          "${pkgs.coreutils}/bin/mkdir -p ${dataDir}/data/settings ${dataDir}/data/admin ${dataDir}/data/admin-state ${dataDir}/data/telemetry"
        ];

        ReadWritePaths = [ dataDir ];

        CapabilityBoundingSet = [ "" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        LockPersonality = true;
      };
    };

    services.nginx = {
      enable = true;
      virtualHosts.${webmailHostname} = {
        forceSSL = true;
        enableACME = false;
        sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString port}";
          proxyWebsockets = true;
          recommendedProxySettings = true;
        };
      };
    };
  };
}
```

**Step 2: Verify the role is auto-discovered**

```bash
nix eval path:.#nixosConfigurations.mokosh.options.roles.webmail.enable.isDefined || true
```

The role should be picked up by `roles/default.nix` auto-discovery since it's a `.nix` file directly under `roles/`.

**Step 3: Commit**

```bash
git add roles/webmail.nix
git commit -m "feat: add bulwark webmail role module"
```

---

### Task 4: Enable webmail on mokosh

**Files:**
- Modify: `machines/mokosh/default.nix:69-73`

**Step 1: Add the webmail role config**

Add after the `roles.mail` block (around line 73):

```nix
roles.webmail = {
  enable = true;
  baseDomain = domainName;
  jmapServerUrl = "http://127.0.0.1:10080";
};
```

**Step 2: Verify the full config evaluates**

```bash
make check
```

Expected: `nix flake check` passes. If there are hash issues with the package, fix them first (Task 1 Step 3-4).

**Step 3: Commit**

```bash
git add machines/mokosh/default.nix
git commit -m "feat: enable bulwark webmail on mokosh"
```

---

### Task 5: Format and final check

**Step 1: Format all changed files**

```bash
nixfmt pkgs/bulwark-webmail/default.nix overlays/default.nix roles/webmail.nix machines/mokosh/default.nix
```

**Step 2: Run flake check**

```bash
make check
```

Expected: all checks pass.

**Step 3: Commit any formatting fixes**

```bash
git add -u
git commit -m "style: format nix files"
```

---

## Notes

- The `npmDepsHash` and source `hash` are placeholders (`sha256-PLACEHOLDER`). They must be computed during implementation by running `nix-prefetch-url` and `prefetch-npm-deps`.
- Bulwark's `next.config.ts` already sets `output: "standalone"`, confirmed from source.
- The `next build` command in the Dockerfile uses `--webpack` flag (not `--turbopack`). The `buildNpmPackage` `npmBuildScript = "build"` will run `next build` which uses turbopack by default in the package.json scripts. May need to override the build command to use `--webpack` if turbopack fails in Nix sandbox.
- `nodejs_24` is available in nixos-25.11 (confirmed).
- The webmail's setup wizard will run on first launch. Admin password and branding will be configured through the wizard, persisted in `/var/lib/bulwark-webmail/data/admin/`.
