# Self-hosted Headscale and Tailscale

**Status:** approved
**Date:** 2026-09-06

## Goal

Create a private overlay network without using Tailscale's hosted control
plane. `mokosh` will run Headscale as the control plane and its embedded
DERP/STUN relay, with Headplane as the administrative UI. `nixpi` will be the
only Nix-configured tailnet client in this phase; its enrollment is a one-time
operator action.

The existing WireGuard connection between `mokosh` and `nixpi` remains active
and unmodified. Tailscale is a new, parallel connection that will be validated
before WireGuard is considered for retirement.

## Scope

- Add `roles.vpn`, a server-side composition role that wraps the native
  NixOS Headscale and Headplane modules.
- Enable the role only on `mokosh`.
- Serve the control plane at `https://headscale.uspenskiy.tech` with the
  existing `uspenskiy.tech` ACME certificate.
- Enable Headscale's embedded DERP/STUN server on `mokosh` and serve no
  Tailscale-operated DERP map.
- Enable the native Tailscale client on `nixpi` and document its one-time
  enrollment with this Headscale instance.
- Protect the Headplane UI at `/admin/` with HTTP Basic Auth and Headplane's
  Headscale-API-key login.
- Back up Headscale's SQLite database and private identity key through the
  existing SQLite snapshot and Restic infrastructure.
- Add the declarative DNS record for `headscale.uspenskiy.tech`.

## Non-Goals

- Do not join `mokosh` to the tailnet in this phase.
- Do not enroll other machines declaratively or migrate their access.
- Do not remove, alter, or reuse the existing `wg0`/`wg-client` WireGuard
  configuration, its keys, its `10.20.0.0/24` addresses, or its routes.
- Do not configure a subnet router, exit node, Tailscale SSH, MagicDNS, ACL
  policy beyond Headscale's safe initial policy, or a second DERP relay.
- Do not use an OCI container, new flake input, custom package derivation, or
  hosted Tailscale control-plane service.
- Do not add OIDC or another identity provider for Headplane.

## Architecture

`roles.vpn` is a focused server-side role. It owns Headscale, Headplane,
Nginx exposure, DERP/STUN firewall exposure, state, and backup integration.
It deliberately does not enable `services.tailscale` on its host or manage
enrollment of other hosts.

`machines/mokosh/default.nix` will enable the role with these inputs:

- `hostname = "headscale.uspenskiy.tech"`;
- the existing `/var/lib/acme/uspenskiy.tech` certificate directory;
- `mokosh`'s public IPv4 address for DERP/STUN advertisement.

The role will configure native Headscale and Headplane services to listen only
on loopback. Nginx will terminate TLS and proxy the control-plane endpoints at
`/` to Headscale and the supported `/admin/` prefix to Headplane. The Nginx
configuration must include Headplane's required WebSocket and forwarded-header
settings. No application TCP port will be exposed directly.

Headscale's public `server_url` will be
`https://headscale.uspenskiy.tech`. Its embedded DERP server will advertise
the configured public IPv4 address; STUN will be publicly reachable on UDP
3478. The Headscale DERP URL list will be empty, so clients are not given
Tailscale's default public DERP relays. This makes `mokosh` the single fallback
relay; direct peer-to-peer paths remain preferred whenever NAT traversal
succeeds.

```text
Tailscale client (later manual enrollment)       nixpi
                    |                              |
                    +-- direct encrypted path ------+
                    |          (preferred)
                    |
                    +-- encrypted DERP fallback ----+
                                           |
                                        mokosh
                         UDP 3478 STUN / embedded DERP
                                           |
                       HTTPS :443        +-- Headscale (loopback)
Internet clients ------------------------+-- Headplane /admin (loopback)
                                           |
                                  Nginx + existing ACME certificate
```

`nixpi` will use only the native Tailscale client configured with Headscale's
public login-server URL. Its persistent Tailscale state is independent from
the existing `wg-client` state. `mokosh` provides control-plane and relay
services but is not a tailnet peer.

## Role and File Boundaries

Create `roles/vpn.nix`, which declares `roles.vpn.enable` and the minimal
server-specific inputs described above. It will:

- configure `services.headscale` with an explicit SQLite database path under
  `/var/lib/headscale` and its public URL, loopback listener, and embedded
  DERP-only map;
- configure `services.headplane` on loopback with the public base URL,
  secure session cookie, and Headscale configuration visibility;
- keep Headplane's agent and native process integration disabled, preserving
  Nix as the source of truth for Headscale configuration;
- create the Nginx virtual host and open only UDP 3478 beyond existing HTTPS;
- create the Headscale database backup and add it to the existing backup role.

`machines/mokosh/default.nix` will enable this role. `machines/nixpi/default.nix`
will enable the native client without touching `roles.wireguard-client`.

The implementation will add an unproxied A record for `headscale` in the
`uspenskiy.tech` declarative DNS zone pointing to `mokosh`. DNS work must use
the repository's `managing-dns` workflow when it is implemented.

## Administration and Secrets

Headplane is a convenience interface for Headscale users and nodes, not a
configuration-management plane. It can view declarative Headscale settings,
but it will not receive permission to edit or restart Headscale. This prevents
UI changes from creating undeclared configuration drift.

Nginx will require HTTP Basic Auth before proxying `/admin/`. Headplane will
then require the administrator to log in with a Headscale API key. This is a
second, independent layer and avoids adding OIDC for a single administrator.

Add encrypted file secrets for:

- the Nginx bcrypt/`htpasswd` file that guards `/admin/`;
- Headplane's stable, exactly 32-character session-cookie secret.

Neither secret, nor a Headscale API key, belongs in Nix source, the Nix store,
or `secrets.json`. An API key is created locally through the Headscale CLI as
needed and entered interactively into Headplane; it is not stored in the
declarative server configuration.

## Bootstrap and Operation

After deploying `mokosh`, the operator will use the local Headscale CLI to:

1. create the initial Headscale user;
2. create a single-use, expiring pre-authentication key for that user;
3. enroll `nixpi` with `tailscale up --login-server` and that key;
4. revoke or allow the single-use key to expire.

The Headscale database retains the registration, so ordinary restarts and
rebuilds do not require re-enrollment. Additional clients are intentionally
manual follow-up enrollments, outside this Nix configuration scope.

## Persistent Data and Backups

Headscale's explicit SQLite database and long-lived private key under
`/var/lib/headscale` are authoritative state. `roles.vpn` will reuse
`common/sqlite-backup.nix` to make a SQLite-consistent nightly copy in
`/var/backup/headscale`, preserving the private key alongside it. The helper
will run as the Headscale service account so it can read that state safely.

The role will add `/var/backup/headscale` to `roles.backup.paths` and add
`backup-headscale.service` to `roles.backup.afterServices`. Consequently the
existing Restic run occurs after the fresh database snapshot, while the
helper's independent timer is disabled by the backup role.

Headplane's cache and UI-local state are non-authoritative and are not part of
the backup set. The Headscale configuration is declarative and can be restored
by rebuilding the system.

To restore Headscale, stop its service, restore the SQLite snapshot and private
key with the Headscale account's correct ownership and mode, then start the
service and confirm the node inventory. This recovery procedure will be
documented in the implementation plan.

## Failure Handling

- A Headscale or Nginx outage prevents new registrations and control updates;
  already-established direct node connections can continue until they require
  new coordination.
- A DERP/STUN outage affects only nodes that cannot establish direct paths;
  it does not replace existing direct connections.
- There is intentionally no hosted-control-plane or external-DERP fallback.
  `mokosh` is the single control-plane and relay availability dependency.
- A missing or malformed encrypted UI secret prevents the relevant service
  from starting securely; it must fail explicitly rather than generate a new
  session secret.
- A failed SQLite snapshot is visible as a failed `backup-headscale.service`.
  The Restic service ordering prevents it from silently running first.

## Verification

Implementation verification will cover:

1. Format changed Nix files with `nixfmt` and run `git diff --check`.
2. Evaluate the affected configurations and run `make check`, using dummy
   secrets when the real secrets are unavailable.
3. Confirm the DNS declaration, ACME-backed HTTPS control endpoint, Nginx
   proxy routing, loopback-only application listeners, and UDP 3478 firewall
   rule on `mokosh`.
4. Confirm that Headscale and Headplane are active and that `/admin/` requires
   HTTP Basic Auth plus a Headscale API-key login.
5. Enroll `nixpi` with the one-time key and confirm its registered state,
   `tailscale status`, `tailscale netcheck`, and a DERP-map check showing the
   self-hosted relay configuration.
6. Manually enroll a later client, reach `nixpi` by its Tailscale address, and
   confirm the existing WireGuard path remains operational in parallel.
7. Review the final file scope; no WireGuard configuration may have changed.

The repository has no automated test suite for this service type. Nix
evaluation, `make check`, deployment health checks, and the connection smoke
test are the appropriate validation layers.

## Expected File Changes

- `roles/vpn.nix`: new Headscale/Headplane server role, Nginx, firewall, and
  Headscale backup integration.
- `machines/mokosh/default.nix`: enable `roles.vpn` with the selected hostname,
  ACME directory, and public IPv4.
- `machines/nixpi/default.nix`: enable the native Tailscale client for later
  one-time Headscale enrollment; retain the current WireGuard client unchanged.
- `dns/zones/uspenskiy-tech.nix`: declare the `headscale` A record for
  `mokosh`.
- `secrets/unlocked/spec.txt`: deploy the Headplane cookie secret and Nginx
  Basic Auth file to `mokosh`.
- `README.md`: add the VPN role and its control-plane endpoint to repository
  documentation.
- `docs/superpowers/plans/2026-09-06-headscale-tailscale.md`: implementation
  plan created only after this design is reviewed.

No implementation changes are planned for the existing WireGuard roles,
`common/sqlite-backup.nix`, `flake.nix`, or `flake.lock`.

## Alternatives Considered

### Direct Machine Configuration

Configuring Headscale and Headplane directly in `machines/mokosh/default.nix`
would be smaller today, but would conflate the service's internal composition
with machine-specific decisions. `roles.vpn` provides a concise, reusable
boundary while retaining native NixOS modules.

### Container Deployment

Containers would duplicate native NixOS service support and add image,
network, state, and upgrade handling. Native services fit this repository's
configuration model better.

### Joining Mokosh Immediately

`mokosh` can host the control plane and embedded DERP relay without becoming a
tailnet node. Keeping it out initially minimizes the new network surface. It
can be enrolled later if private overlay access to the host becomes useful.

### OIDC for Headplane

OIDC would improve centralized identity management for multiple administrators
but introduces an identity provider and its credentials. Basic Auth plus the
Headscale API-key login is sufficient for this single-administrator phase.
