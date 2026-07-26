# RSSHub on Mokosh

**Status:** approved
**Date:** 2026-07-26

## Goal

Deploy RSSHub on `mokosh` as a private, browser-free feed generator used by
the existing Miniflux instance. The first required route is
`/anthropic/research`.

RSSHub must be reachable by Miniflux on the same host, but it must not be
reachable from the public network.

## Scope

- Add RSSHub support to the existing `roles.rss` role.
- Place the module in `roles/reading/rss/rsshub.nix`.
- Expose the enable option as `roles.rss.hub.enable`, matching the existing
  `roles.rss.summarizer.enable` structure.
- Use the nixpkgs `services.rsshub` module and package.
- Listen on `127.0.0.1:1200` only.
- Use RSSHub's in-memory cache.
- Verify the `anthropic/research` route without a headless browser.
- Document the additional RSS role component.

## Non-Goals

- No public `rsshub.uspenskiy.tech` endpoint, DNS record, Nginx virtual host,
  ACME certificate, or firewall rule.
- No Redis deployment.
- No Chromium, browserless, Puppeteer, or Playwright deployment.
- No custom RSSHub package, flake input, overlay, or GitHub Actions build.
- No declarative Miniflux feed/database changes.
- No changes to RSSHub routes or upstream source.

## Decisions

### Native NixOS Service

Use the existing nixpkgs `services.rsshub` module rather than Docker or a
custom source build. The module provides a systemd service with a dynamic
service user, a state directory, restart-on-failure behavior, and systemd
hardening. It also provides the RSSHub package from the pinned nixpkgs input.

The exact package selected by the locked `mokosh` configuration is:

```text
rsshub-0-unstable-2026-05-14
```

At design time, the exact output path was available from
`https://cache.nixos.org`. The existing `common/cache.nix` preserves the
official cache and adds the repository's Yandex cache, so no custom builder is
needed.

### Role Placement

`roles/reading/rss/rsshub.nix` will declare `roles.rss.hub.enable` and be
imported by `roles/reading/rss/default.nix`. The module will assert that the
parent `roles.rss.enable` option is enabled, because RSSHub is being deployed
as a companion to Miniflux rather than as an independent public service.

`machines/mokosh/default.nix` will set `hub.enable = true` in its existing
`roles.rss` configuration.

### Network Exposure

The service will use the nixpkgs module's loopback-only behavior explicitly:

```nix
services.rsshub = {
  enable = true;
  redis.enable = false;
  settings = {
    PORT = 1200;
    LISTEN_INADDR_ANY = false;
    CACHE_TYPE = "memory";
  };
};
```

Port `1200` is not opened in the firewall. No Nginx configuration is needed.
Miniflux will consume the route as:

```text
http://127.0.0.1:1200/anthropic/research
```

The public hostname considered during brainstorming is intentionally not part
of this design because localhost-only access is the selected boundary.

### Cache

Redis is explicitly disabled and RSSHub is configured with its in-memory cache.
For one low-volume RSSHub process, this avoids another daemon and its memory
overhead. Losing the cache during a restart is acceptable: Miniflux can fetch
the route again, and RSSHub's route cache is not the source of truth.

Redis can be considered later if multiple RSSHub instances, high route volume,
or cache survival across restarts becomes necessary. It is not required for
the initial route.

### Browser-Free Route

The current upstream `anthropic/research` implementation uses HTTP fetching
and HTML parsing through `ofetch` and `cheerio`. It does not declare
`requirePuppeteer` and does not require a browser runtime.

The route parses Anthropic's current Next.js page data and article HTML. It is
therefore browser-free but structurally coupled to Anthropic's page format;
upstream page changes may require an RSSHub update.

Other RSSHub routes may require Puppeteer or Playwright. Such routes are out
of scope and must not be treated as supported by this deployment.

## Data Flow

```text
Miniflux
  |
  | HTTP over loopback
  v
RSSHub :1200
  |
  | HTTPS outbound request
  v
www.anthropic.com/research
```

Miniflux feed configuration remains application data. After deployment, the
route can be added to Miniflux using the localhost URL above; this design does
not modify the Miniflux database or introduce secrets for it.

## Failure Handling

- systemd restarts RSSHub after process failure using the nixpkgs module's
  existing service policy.
- RSSHub route failures remain visible in the system journal and as failed HTTP
  responses; Miniflux remains responsible for its normal feed retry behavior.
- A temporary Anthropic outage must not expose RSSHub publicly or require a
  separate proxy service.
- A cache loss after restart is acceptable and should not block service startup.
- If a future route requires a browser, it must be handled as a separate design
  decision rather than silently adding browser dependencies here.

## Verification

Repository validation will cover:

1. `nixfmt` on all changed Nix files.
2. Evaluation that `roles.rss.hub.enable` produces the expected
   `services.rsshub` configuration.
3. Confirmation that the locked RSSHub output is substitutable from
   `https://cache.nixos.org`.
4. `make check` for the full flake.
5. A runtime check on `mokosh` that `rsshub.service` is active and
   `http://127.0.0.1:1200/healthz` responds successfully.
6. A runtime request to `/anthropic/research` that returns a non-empty RSS or
   Atom response without launching a browser service.
7. A negative exposure check confirming that no RSSHub port is added to the
   firewall and the service is not listening on the external address.

The implementation will not add an automated test framework. This repository
validates NixOS changes through evaluation, flake checks, and deployment
smoke tests.

## Expected File Changes

- `roles/reading/rss/rsshub.nix`: declare and implement the nested RSSHub
  role.
- `roles/reading/rss/default.nix`: import the RSSHub module.
- `machines/mokosh/default.nix`: enable `roles.rss.hub`.
- `README.md`: mention RSSHub under the reading/RSS role and document that the
  initial service is localhost-only.
- `docs/superpowers/specs/2026-07-26-rsshub-mokosh-design.md`: this design.
- `docs/superpowers/plans/2026-07-26-rsshub-mokosh.md`: the implementation
  plan created after this spec is reviewed.

No dependency or lockfile changes are expected.

## Alternatives Considered

### Docker Image

The upstream Docker image would track RSSHub releases directly, but Docker or
Podman is not used elsewhere in this NixOS configuration. It would introduce a
new runtime, image lifecycle, and storage model for a service already packaged
and exposed through a NixOS module.

### Custom RSSHub Derivation

A custom derivation would allow selecting an arbitrary upstream revision, but
would duplicate nixpkgs dependency fetching and build maintenance. It provides
no benefit while the pinned package is available from the official binary
cache.

The native NixOS service is the smallest implementation consistent with the
repository's existing role structure and the localhost-only requirement.
