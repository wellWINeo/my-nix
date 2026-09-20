# Mokosh Observability Design

## Goal

Add a declarative, single-host observability stack to mokosh. Grafana is publicly reachable at `grafana.uspenskiy.tech`; VictoriaMetrics and all scrape endpoints remain local. VictoriaMetrics is configured with a 30-day retention period (and may retain data slightly longer at storage-partition boundaries) and scrapes every 60 seconds. Alerting is explicitly out of scope.

## Scope

The first release collects:

- Basic mokosh host metrics from Prometheus node exporter: CPU, load, memory, swap, filesystem and inode capacity, network traffic, and selected systemd-unit state.
- Native Prometheus/OpenMetrics endpoints from the currently enabled services that document such support: Headscale, Miniflux, and Stalwart Mail.
- VictoriaMetrics and Grafana self-metrics.

No third-party application exporters are added. Vaultwarden, Readeck, Calibre-Web, RSSHub, Shadowsocks, and the Anytype MCP bridge are excluded because they do not currently expose a documented native Prometheus/OpenMetrics endpoint suitable for this deployment.

The release does not add alerts, HTTP uptime probes, logs, traces, remote write, federation, or a remote scrape agent.

## Module structure

Create `roles/observability/`, which is discovered as one role through its `default.nix`:

- `roles/observability/default.nix`
  - Imports the child modules.
  - Defines `roles.observability.enable`.
  - Defines an internal, append-only `roles.observability.scrapeJobs` option used by source-owning roles to register a Prometheus-compatible scrape job.
  - When enabled, sets `roles.vpn.metrics.enable`, `roles.rss.metrics.enable`, and `roles.mail.metrics.enable` with `mkDefault`, allowing a host to override a specific source to `false`.
- `roles/observability/node-exporter.nix`
  - Enables the NixOS Prometheus node exporter bound to loopback.
  - Enables its `systemd` collector and registers the `node` job.
- `roles/observability/victoria-metrics.nix`
  - Runs single-node VictoriaMetrics bound to `127.0.0.1:8428` with `retentionPeriod = "30d"`; its storage partitions may retain samples briefly beyond that boundary.
  - Converts the aggregated scrape jobs to `services.victoriametrics.prometheusConfig.scrape_configs` and sets the global 60-second scrape interval.
  - Registers VictoriaMetrics' own `/metrics` endpoint.
- `roles/observability/grafana.nix`
  - Runs Grafana on `127.0.0.1:3000`.
  - Adds the nginx virtual host, configures security settings, provisions the local VictoriaMetrics datasource and the dashboard directory, and registers Grafana's own `/metrics` endpoint.
- `roles/observability/dashboards/mokosh-overview.json`
  - Contains the Git-managed `Mokosh Overview` dashboard.

## Source ownership and integration interface

A role that owns an application also owns that application's metrics listener and scrape-job contribution. It adds a nested `metrics.enable` option and gates metric configuration on both the application role's `enable` and its own `metrics.enable`.

The initial source integrations are:

| Application role | Metrics configuration it owns | Job it contributes |
| --- | --- | --- |
| `roles.vpn` | Headscale `metrics_listen_addr` bound to a loopback port | `headscale` |
| `roles.rss` | Miniflux native collector enabled, allowed only from `127.0.0.1/8` | `miniflux` |
| `roles.mail` | Stalwart's native Prometheus endpoint enabled on its existing loopback-only management HTTP listener | `stalwart` |

Each job has a stable `job` name and `host = "mokosh"` label. A job supplies its target, metrics path, scheme, and any endpoint-specific scrape settings. `roles.observability` consumes these registrations but contains no Headscale, Miniflux, or Stalwart port/path knowledge.

This interface is deliberately local to NixOS modules: to instrument a future application, its owning role adds its metrics option, listener, and scrape-job contribution. The VictoriaMetrics module remains unchanged.

## Networking and security

- Node exporter, Headscale metrics, Miniflux metrics, Stalwart metrics, VictoriaMetrics, and Grafana bind only to loopback. They do not open firewall ports.
- Existing public nginx virtual hosts must explicitly return `404` for Miniflux `/metrics` and Stalwart `/metrics/prometheus`; Grafana's public virtual host must return `404` for `/metrics`. This prevents public catch-all reverse proxies from forwarding the otherwise loopback-only native endpoints.
- Grafana is the only public component. `grafana.uspenskiy.tech` is reverse-proxied by nginx to `127.0.0.1:3000`, uses `forceSSL`, the existing `uspenskiy.tech` wildcard certificate, and NixOS' recommended proxy settings.
- Grafana sets its public domain/root URL, enforces the domain, disables anonymous access and self-signup, and uses secure cookies. Its datasource is the loopback VictoriaMetrics URL and is not user-editable.
- Grafana's initial administrator username is `o__ni`.
- Add `mokosh:grafana.env:0400:root:root` to `secrets/unlocked/spec.txt`. The locked file contains `GF_SECURITY_ADMIN_USER=o__ni`, a generated `GF_SECURITY_ADMIN_PASSWORD`, and a generated persistent `GF_SECURITY_SECRET_KEY`. PID 1 reads this root-owned `EnvironmentFile` before starting Grafana, keeping both values out of the Nix store and allowing installation before the Grafana account exists.
- Update `dns/zones/uspenskiy-tech.nix` with the proxied, auto-TTL CNAME `grafana -> mokosh.uspenskiy.tech.`. The existing wildcard ACME certificate already covers this subdomain.

## Grafana experience

Provision the VictoriaMetrics datasource using Grafana's Prometheus datasource type and `http://127.0.0.1:8428` server-side URL. Provision `Mokosh Overview` from the dashboard JSON; no dashboard is created manually in the UI.

The dashboard includes:

- CPU utilization and load;
- memory and swap usage;
- disk free space and inode availability;
- network traffic;
- selected systemd unit health, including `stalwart.service`;
- per-job `up`, scrape duration, and samples-scraped panels;
- dashboard variables or links that make the native application series discoverable in Explore.

Application-specific metric series are stored and available to Explore. The first dashboard intentionally uses generic scrape-health panels rather than version-sensitive application metric names.

## Machine configuration

`machines/mokosh/default.nix` enables the role and supplies the `uspenskiy.tech` base domain needed by Grafana's nginx virtual host. No other machine enables it. The role directory is imported automatically by `roles/default.nix`.

## Verification

Before deployment:

1. Format all Nix changes with `nixfmt .`.
2. Create dummy JSON secrets if needed with `make setup-dummy-secrets`.
3. Run the DNS offline checks required by the DNS skill: `make fmt`, `nix build ".#checks.$(nix eval --impure --raw --expr builtins.currentSystem).dns-render" ".#checks.$(nix eval --impure --raw --expr builtins.currentSystem).dns-config" ".#checks.$(nix eval --impure --raw --expr builtins.currentSystem).dns-app-safety"`, then `make check`.
4. Verify the mokosh NixOS configuration evaluates through `make check`.

After deployment, confirm Grafana, VictoriaMetrics, node exporter, and each enabled source service are active; query VictoriaMetrics' targets API from the host and fail verification unless every expected job is present and healthy; verify the dashboard JSON with `jq empty`; and log in to `https://grafana.uspenskiy.tech` as `o__ni` to confirm the provisioned datasource and dashboard load.
