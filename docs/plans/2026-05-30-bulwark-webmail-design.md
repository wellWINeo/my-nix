# Bulwark Webmail Integration

## Goal

Add [Bulwark Webmail](https://github.com/bulwarkmail/webmail) as a NixOS role, built from source and served behind nginx alongside the existing Stalwart mail server on mokosh.

## Context

- Stalwart mail server is already running on mokosh with a JMAP/HTTP listener on `127.0.0.1:10080`
- Bulwark is a Next.js 16 app (Node.js 24) that connects to a JMAP server and provides webmail, calendar, contacts, and files
- Current version: v1.7.2
- Build: multi-stage Dockerfile — `npm ci` + `npx next build --webpack` producing a standalone output

## Architecture

```
User browser
  → nginx (webmail.uspenskiy.su:443, TLS)
    → bulwark-webmail (127.0.0.1:11080, Node.js)
      → Stalwart JMAP (127.0.0.1:10080, HTTP)
```

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Packaging | Build from source (fetchFromGitHub) | Native Nix package, no Docker dependency |
| Source fetching | fetchFromGitHub inline in derivation | No extra flake input, version pinned in nix file |
| Role structure | Separate `roles/webmail.nix` + `pkgs/bulwark-webmail/default.nix` | Clean separation of package and service |
| Configuration | Hybrid (env vars for JMAP URL + setup wizard for branding/secrets) | JMAP URL is declarative, branding managed via admin UI |
| SSL | `baseDomain` pattern matching other roles | Consistent with vault, blog, calibre, rss, etc. |
| JMAP connection | Direct localhost (127.0.0.1:10080) | No TLS overhead, no nginx hop |
| Internal port | 11080 | Unused on mokosh |
| Webmail URL | `webmail.<baseDomain>` | Clean subdomain, separate from `mail.<baseDomain>` |

## Files

### `pkgs/bulwark-webmail/default.nix` — Package derivation

Builds the Next.js standalone output from GitHub source:

- `fetchFromGitHub` with owner `bulwarkmail`, repo `webmail`, pinned to v1.7.2
- Uses `buildNpmPackage` with Node.js 24
- Build steps: `npm ci` + `npx next build --webpack` (standalone output)
- Installs: standalone server + `.next/static` + `public/`
- Produces a runnable directory with `server.js` as entry point

### `roles/webmail.nix` — NixOS service module

New role, auto-discovered by `roles/default.nix`.

**Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | false | Enable Bulwark webmail |
| `baseDomain` | str | — | Base domain (certs at `/var/lib/acme/<baseDomain>/`) |
| `port` | int | 11080 | Internal listen port |
| `jmapServerUrl` | str | — | JMAP server URL |
| `sessionSecretFile` | null or path | null | File containing session secret |
| `stalwartFeatures` | bool | true | Enable Stalwart-specific features |

**Systemd service `bulwark-webmail.service`:**

- `DynamicUser = true`, `StateDirectory = "bulwark-webmail"`
- Working directory: `/var/lib/bulwark-webmail`
- PreStart: create `data/{settings,admin,admin-state,telemetry}`
- Environment: `HOSTNAME=127.0.0.1`, `PORT`, `NODE_ENV=production`, `JMAP_SERVER_URL`, `STALWART_FEATURES`
- `ExecStart`: `node ${pkgs.bulwark-webmail}/server.js`
- After `network-online.target`

**Nginx vhost** for `webmail.${cfg.baseDomain}`:

- SSL certs: `/var/lib/acme/${cfg.baseDomain}/{fullchain,key}.pem`
- Proxy pass to `http://127.0.0.1:${cfg.port}`
- `recommendedProxySettings = true`

### `roles/communication/mail.nix` — No changes

Mail role stays unchanged. Wiring happens in the machine config.

### `machines/mokosh/default.nix` — Enable webmail role

```nix
roles.webmail = {
  enable = true;
  baseDomain = domainName;
  jmapServerUrl = "http://127.0.0.1:10080";
};
```

### `flake.nix` / `overlays/default.nix` — Add overlay

Add `bulwark-webmail` package via overlay so it's available in `pkgs`.

## Configuration flow

1. NixOS sets `JMAP_SERVER_URL=http://127.0.0.1:10080` and `STALWART_FEATURES=true` via systemd Environment
2. On first launch, the Bulwark setup wizard runs at `https://webmail.uspenskiy.su`
3. Admin completes the wizard: sets admin password, configures branding, generates session secret
4. Config is persisted in `/var/lib/bulwark-webmail/data/admin/`
5. Subsequent changes made through the admin dashboard

## Risks

- **npm build complexity**: Next.js builds with npm can be finicky in Nix. The `buildNpmPackage` approach requires correct `npmDepsHash`. May need iterations to get the hash right.
- **Node.js 24 availability**: Need to verify `nodejs_24` is available in nixos-25.11. If not, may need nixpkgs-unstable for the Node package.
- **Standalone output**: Bulwark's `next.config.ts` must have `output: "standalone"` for this to work. The Dockerfile assumes it — need to verify.
- **Memory**: mokosh has 2GB RAM. Next.js build may be heavy. Runtime should be fine (~100-200MB).
