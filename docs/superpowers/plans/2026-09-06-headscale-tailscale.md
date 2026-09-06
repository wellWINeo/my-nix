# Self-hosted Headscale and Tailscale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a self-hosted Headscale control plane and Headplane UI on
`mokosh`, and add `nixpi` as the first Tailscale client without changing the
existing WireGuard connection.

**Architecture:** `roles.vpn` composes the native NixOS Headscale and
Headplane services, Nginx, embedded DERP/STUN, and the repository's SQLite
backup utility. `mokosh` is only the control-plane/DERP host; `nixpi` runs the
Tailscale daemon and is enrolled manually with a single-use Headscale key.

**Tech Stack:** NixOS 26.05 native `services.headscale`,
`services.headplane`, and `services.tailscale`; Nginx; ACME; Headscale SQLite;
Headplane; Cloudflare declarative DNS; Restic; `common/sqlite-backup.nix`.

## Global Constraints

- Create `roles.vpn`; do not configure Headscale/Headplane ad hoc only in the
  mokosh machine module.
- Use `https://headscale.uspenskiy.tech`, the existing
  `/var/lib/acme/uspenskiy.tech` certificate, and an unproxied DNS A record.
- Headscale and Headplane listen on loopback only; Nginx alone exposes HTTPS.
- Enable Headscale's embedded DERP/STUN with `mokosh`'s public IPv4 and set
  `derp.urls = [ ]` and `derp.auto_update_enabled = false`.
- Disable MagicDNS and local-DNS override in Headscale because this phase does
  not configure tailnet DNS.
- Protect only Headplane's `/admin/` route with HTTP Basic Auth. Never put
  Basic Auth in front of Headscale's `/` control endpoints; mobile clients need
  those endpoints without an HTTP-auth challenge.
- Keep Headplane agent and native process integration disabled. Headplane must
  not modify or restart declarative Headscale configuration.
- Keep all Headscale state local SQLite. Back up its consistent snapshot plus
  `noise_private.key` and `derp_server_private.key` before the existing Restic
  service runs.
- Do not persist a Headscale API key or a pre-auth key in Nix configuration,
  `secrets.json`, or the Nix store.
- Do not modify any `roles.wireguardRouter`, `roles.wireguard-client`,
  `wg0`, `wg-client`, WireGuard keys, WireGuard routes, or `10.20.0.0/24`.
- Do not add a subnet router, exit node, Tailscale SSH, OIDC, a second DERP,
  a new flake input, or container runtime.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `roles/vpn.nix` | `roles.vpn` interface and native Headscale/Headplane, Nginx, DERP/STUN, and backup composition. |
| `machines/mokosh/default.nix` | Enables `roles.vpn` using the chosen hostname, ACME directory, and public IPv4. |
| `machines/nixpi/default.nix` | Enables the native Tailscale daemon only; enrollment remains an operator command. |
| `secrets/unlocked/spec.txt` | Installs the Headplane cookie secret and Nginx Basic Auth file with service-readable permissions. |
| `dns/zones/uspenskiy-tech.nix` | Declares the unproxied public A record for the Headscale hostname. |
| `README.md` | Documents the VPN role, endpoint, scope, and WireGuard coexistence. |

### Task 1: Create the VPN role, secrets contract, and Mokosh service composition

**Files:**

- Create: `roles/vpn.nix`
- Modify: `machines/mokosh/default.nix`
- Modify: `secrets/unlocked/spec.txt`

**Interfaces:**

- Consumes: the auto-import of `roles/default.nix`; `common/sqlite-backup.nix`;
  `roles.backup.paths`; `roles.backup.afterServices`; `domainNames.secondary`;
  `secrets.ip.mokosh.address`; NixOS 26.05 native services.
- Produces: `roles.vpn.enable`, `roles.vpn.hostname`,
  `roles.vpn.certificateDirectory`, and `roles.vpn.publicIPv4`; the
  `backup-headscale.service`; an HTTPS control plane and an `/admin/` UI route.

- [ ] **Step 1: Add the two file-secret installation entries.**

  Add these lines to `secrets/unlocked/spec.txt`:

  ```text
  mokosh:headplane-cookie-secret:0400:headscale:headscale
  mokosh:headplane.htpasswd:0440:root:web
  ```

  `services.headplane` runs as the native Headscale user, so that account must
  read the cookie secret. The nginx account is a member of the existing `web`
  group, so the Basic Auth file is readable to nginx without making it
  world-readable.

- [ ] **Step 2: Generate the encrypted source files without putting values in Nix.**

  On a machine with access to the unlocked secret directory and the GPG key,
  generate the exact 32-character cookie secret and interactively create the
  bcrypt password file:

  ```bash
  umask 077
  openssl rand -hex 16 > secrets/unlocked/headplane-cookie-secret
  nix shell nixpkgs#apacheHttpd -c htpasswd -B -c secrets/unlocked/headplane.htpasswd <admin-user>
  wc -c < secrets/unlocked/headplane-cookie-secret
  ```

  Expected: the final command prints `33`, meaning 32 hex characters plus the
  terminating newline. Verify the password file contains one bcrypt entry for
  the intended administrator. Encrypt the files only after all planned secret
  changes are complete:

  ```bash
  make lock-files
  ```

- [ ] **Step 3: Create `roles/vpn.nix`.**

  Use the repository module convention and import the SQLite helper. Define
  only the four role options below, then compose the services in `mkIf
  cfg.enable`:

  ```nix
  { config, lib, pkgs, ... }:

  with lib;

  let
    cfg = config.roles.vpn;
    dataDir = "/var/lib/headscale";
    backupDir = "/var/backup/headscale";
    headscalePort = 8080;
    headplanePort = 3000;
    mkSqliteBackup = import ../common/sqlite-backup.nix;
  in
  {
    options.roles.vpn = {
      enable = mkEnableOption "self-hosted Headscale VPN control plane";
      hostname = mkOption { type = types.str; };
      certificateDirectory = mkOption { type = types.str; };
      publicIPv4 = mkOption { type = types.str; };
    };

    config = mkIf cfg.enable (mkMerge [
      (mkSqliteBackup {
        inherit lib pkgs;
        name = "headscale";
        databases = [ "${dataDir}/db.sqlite" ];
        backupDir = backupDir;
        user = "headscale";
        group = "headscale";
        extraPaths = [
          "${dataDir}/noise_private.key"
          "${dataDir}/derp_server_private.key"
        ];
      })
      {
        services.headscale = {
          enable = true;
          address = "127.0.0.1";
          port = headscalePort;
          settings = {
            server_url = "https://${cfg.hostname}";
            database = {
              type = "sqlite";
              sqlite = {
                path = "${dataDir}/db.sqlite";
                write_ahead_log = true;
              };
            };
            dns = {
              magic_dns = false;
              override_local_dns = false;
            };
            derp = {
              urls = [ ];
              auto_update_enabled = false;
              server = {
                enabled = true;
                ipv4 = cfg.publicIPv4;
              };
            };
          };
        };

        services.headplane = {
          enable = true;
          settings = {
            server = {
              host = "127.0.0.1";
              port = headplanePort;
              base_url = "https://${cfg.hostname}";
              cookie_secret_path = "/etc/nixos/secrets/headplane-cookie-secret";
              cookie_secure = true;
            };
            headscale = {
              url = "http://127.0.0.1:${toString headscalePort}";
              public_url = "https://${cfg.hostname}";
            };
            integration.proc.enabled = false;
          };
        };

        networking.firewall.allowedUDPPorts = [ 3478 ];
        roles.backup.paths = [ backupDir ];
        roles.backup.afterServices = [ "backup-headscale.service" ];
      }
    ]);
  }
  ```

  Add the Nginx virtual host inside the same final attribute set:

  ```nix
  services.nginx.virtualHosts.${cfg.hostname} = {
    forceSSL = true;
    enableACME = false;
    sslCertificate = "${cfg.certificateDirectory}/fullchain.pem";
    sslCertificateKey = "${cfg.certificateDirectory}/key.pem";

    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString headscalePort}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };

    locations."/admin/" = {
      proxyPass = "http://127.0.0.1:${toString headplanePort}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      basicAuthFile = "/etc/nixos/secrets/headplane.htpasswd";
      extraConfig = "proxy_buffering off;";
    };
  };
  ```

  Do not set `tls_cert_path` or `tls_key_path` on Headscale: Nginx terminates
  TLS and Headscale receives loopback HTTP. Do not set
  `services.headplane.settings.oidc`; leaving it `null` keeps API-key login
  enabled without a persistent Headscale API key. Do not set
  `integration.agent`; its default is `null` and the Headplane agent stays out
  of the tailnet.

- [ ] **Step 4: Enable the role on Mokosh.**

  In the roles section of `machines/mokosh/default.nix`, add:

  ```nix
  roles.vpn = {
    enable = true;
    hostname = "headscale.${domainNames.secondary}";
    certificateDirectory = "/var/lib/acme/${domainNames.secondary}";
    publicIPv4 = secrets.ip.mokosh.address;
  };
  ```

  Keep the existing `roles.wireguardRouter` block unchanged.

- [ ] **Step 5: Format and evaluate the server composition.**

  ```bash
  nixfmt roles/vpn.nix machines/mokosh/default.nix
  make setup-dummy-secrets
  nix eval --json .#nixosConfigurations.mokosh.config.services.headscale.settings
  nix eval --json .#nixosConfigurations.mokosh.config.services.headplane.settings
  nix eval --json .#nixosConfigurations.mokosh.config.networking.firewall.allowedUDPPorts
  ```

  Expected: Headscale has the public HTTPS `server_url`, SQLite at
  `/var/lib/headscale/db.sqlite`, `derp.urls` is empty, DERP auto-update is
  false, MagicDNS and DNS override are false, and the firewall output includes
  `3478`. Headplane must show loopback port `3000`, the public base URL, the
  cookie-secret path, and `integration.proc.enabled = false`.

- [ ] **Step 6: Commit the role and Mokosh configuration.**

  ```bash
  git add roles/vpn.nix machines/mokosh/default.nix secrets/unlocked/spec.txt secrets/locked.tar.gpg
  git commit -m "feat: add self-hosted Headscale VPN role"
  ```

  Include `secrets/locked.tar.gpg` only if Task 1 regenerated it; never add
  `secrets/unlocked/headplane-cookie-secret` or
  `secrets/unlocked/headplane.htpasswd`.

### Task 2: Configure the Nixpi Tailscale client without altering WireGuard

**Files:**

- Modify: `machines/nixpi/default.nix`

**Interfaces:**

- Consumes: the Headscale HTTPS URL produced by Task 1 and the existing NixOS
  native `services.tailscale` module.
- Produces: a persistent local Tailscale daemon and `tailscale0` interface on
  `nixpi`; it does not produce a registration or modify `wg-client`.

- [ ] **Step 1: Add the native Tailscale service next to the existing network roles.**

  Add this standalone block in `machines/nixpi/default.nix`, leaving the
  adjacent `roles.wireguard-client` block byte-for-byte unchanged:

  ```nix
  services.tailscale = {
    enable = true;
    openFirewall = true;
    disableUpstreamLogging = true;
  };
  ```

  `openFirewall = true` admits encrypted Tailscale UDP traffic on the native
  port (`41641`) so direct paths remain possible. `disableUpstreamLogging`
  avoids sending diagnostic logs to Tailscale infrastructure. Do not set
  `authKeyFile` or `extraUpFlags`: both create an autoconnect unit and would
  require storing the single-use Headscale key declaratively.

- [ ] **Step 2: Format and evaluate the client configuration.**

  ```bash
  nixfmt machines/nixpi/default.nix
  make setup-dummy-secrets
  nix eval --json .#nixosConfigurations.nixpi.config.services.tailscale.enable
  nix eval --json .#nixosConfigurations.nixpi.config.services.tailscale.openFirewall
  nix eval --json .#nixosConfigurations.nixpi.config.networking.firewall.allowedUDPPorts
  ```

  Expected: the first two commands print `true`; the firewall list includes
  `41641`. The diff contains no changed line in the `roles.wireguard-client`
  block.

- [ ] **Step 3: Commit the client configuration.**

  ```bash
  git add machines/nixpi/default.nix
  git commit -m "feat: enable Tailscale on nixpi"
  ```

### Task 3: Declare DNS and document the operator-facing boundary

**Files:**

- Modify: `dns/zones/uspenskiy-tech.nix`
- Modify: `README.md`

**Interfaces:**

- Consumes: `mokosh` public IPv4 `104.248.201.56`, the hostname configured in
  Task 1, and the repository's declarative DNS workflow.
- Produces: public DNS for `headscale.uspenskiy.tech` that passes HTTPS and UDP
  directly to `mokosh`, plus repository documentation of the role and rollout.

- [ ] **Step 1: Read the DNS workflow before touching the declaration.**

  Read `.agents/skills/managing-dns/SKILL.md` completely and follow it for the
  remainder of this task. This is mandatory before editing, previewing,
  validating, checking drift, or applying the Cloudflare declaration.

- [ ] **Step 2: Add the unproxied Headscale A record.**

  Add this record to the `records` list in `dns/zones/uspenskiy-tech.nix`:

  ```nix
  {
    type = "A";
    name = "headscale";
    address = "104.248.201.56";
    proxied = false;
    ttl = "auto";
  }
  ```

  It must remain unproxied: Cloudflare's HTTP proxy cannot carry the UDP 3478
  STUN service and must not sit in the control-plane path.

- [ ] **Step 3: Add a concise README operations note.**

  Under the existing roles/operations material in `README.md`, add text that
  states all of the following:

  ```markdown
  `roles.vpn` runs Headscale and Headplane on `mokosh` at
  `https://headscale.uspenskiy.tech`; the Headplane UI is at `/admin/` and is
  protected by HTTP Basic Auth plus a Headscale API key. The embedded DERP/STUN
  relay is self-hosted on mokosh. `nixpi` runs Tailscale in parallel with its
  existing WireGuard client; WireGuard remains the active fallback until a
  separately approved retirement change.
  ```

- [ ] **Step 4: Run the DNS and repository checks required by the DNS skill.**

  At minimum, run the repository's declared commands after the skill's required
  checks:

  ```bash
  make dns:plan
  nixfmt dns/zones/uspenskiy-tech.nix
  git diff --check
  make check
  ```

  Expected: the preview contains exactly one unproxied `headscale` A record;
  evaluation and formatting succeed. Apply DNS only after the preview has been
  reviewed and the DNS skill's apply safeguards are satisfied:

  ```bash
  make dns:apply
  ```

- [ ] **Step 5: Commit the declaration and documentation.**

  ```bash
  git add dns/zones/uspenskiy-tech.nix README.md
  git commit -m "docs: publish Headscale control plane endpoint"
  ```

### Task 4: Deploy, bootstrap, and verify the parallel overlay

**Files:**

- Modify: none

**Interfaces:**

- Consumes: Tasks 1–3, the encrypted file secrets installed on `mokosh`, and
  administrator shell access to `mokosh` and `nixpi`.
- Produces: an enrolled `nixpi` node and deployment evidence that Tailscale
  works in parallel with WireGuard.

- [ ] **Step 1: Deploy secrets and the Mokosh configuration first.**

  On `mokosh`, install the encrypted secret files before switching so the
  services can read them, then build and activate the configuration:

  ```bash
  sudo make install-secrets
  sudo nixos-rebuild switch --flake 'path:.#mokosh'
  systemctl status headscale headplane nginx backup-headscale --no-pager
  ss -ltnup | rg ':(8080|3000|3478|443)'
  curl --fail --head https://headscale.uspenskiy.tech/health
  curl --fail --user '<admin-user>' --head https://headscale.uspenskiy.tech/admin/
  ```

  Expected: Headscale, Headplane, and Nginx are active; ports 8080 and 3000
  bind only to loopback; UDP 3478 and HTTPS are reachable as intended;
  `/health` succeeds without Basic Auth and `/admin/` succeeds only with the
  configured Basic Auth credentials. Confirm an unauthenticated `/admin/`
  request returns `401`.

- [ ] **Step 2: Bootstrap the first Headscale user and a one-time key.**

  On `mokosh`, create a user, inspect its numeric ID, then issue a single-use
  expiring key:

  ```bash
  sudo headscale users create <user>
  sudo headscale users list
  sudo headscale preauthkeys create --user <user-id>
  ```

  The native Headscale default is a single-use key that expires after one hour.
  Copy the printed key only into the immediate enrollment command. Do not add
  it to a file in the repository, `/etc/nixos/secrets`, or a Nix option.

- [ ] **Step 3: Deploy and enroll Nixpi.**

  On `nixpi`, activate the configuration, then use the one-time key once:

  ```bash
  sudo nixos-rebuild switch --flake 'path:.#nixpi'
  sudo tailscale up \
    --login-server=https://headscale.uspenskiy.tech \
    --auth-key=<single-use-preauth-key>
  tailscale status
  tailscale netcheck
  tailscale debug derp-map
  ```

  Expected: the local control URL is Headscale, `nixpi` is online in
  `sudo headscale nodes list` on `mokosh`, and the DERP map contains the
  embedded `mokosh` relay but no fetched Tailscale default map. On `nixpi`,
  `ip addr show wg-client` and an existing WireGuard-reachable destination must
  still work unchanged.

- [ ] **Step 4: Validate from a manually enrolled mobile or desktop client.**

  Configure the Tailscale app's alternate/custom control server as
  `https://headscale.uspenskiy.tech`, complete its normal Headscale approval or
  use a new short-lived pre-auth key, and then test:

  ```bash
  tailscale status
  tailscale ping nixpi
  ```

  Expected: mobile enrollment does not encounter the `/admin/` Basic Auth
  prompt, because the client uses Headscale control endpoints at `/`; the peer
  can reach `nixpi` by its assigned Tailscale address. `tailscale ping` should
  report a direct path when NAT permits it, or a DERP relay fallback otherwise.

- [ ] **Step 5: Record deployment results without retiring WireGuard.**

  Record the deployed Headscale version, `nixpi` tailnet address, direct-or-
  DERP connection result, and WireGuard coexistence result in the deployment
  handoff. Do not remove any WireGuard configuration. A separate approved plan
  is required before phasing it out.

## Final Verification Checklist

- [ ] `git diff --check` reports no whitespace errors.
- [ ] `make check` passes with real or dummy secrets as appropriate.
- [ ] `headscale.uspenskiy.tech` is an unproxied DNS A record for mokosh.
- [ ] Headscale and Headplane expose no direct public application ports.
- [ ] `/admin/` has Basic Auth while Headscale root endpoints remain reachable
  by desktop and mobile Tailscale clients.
- [ ] Only `nixpi` is Nix-configured as a Tailscale client; `mokosh` is not a
  tailnet node.
- [ ] Headscale uses only the embedded DERP map; its SQLite and private-key
  backup is configured through the existing backup role.
- [ ] Existing WireGuard configuration and connectivity remain intact.
