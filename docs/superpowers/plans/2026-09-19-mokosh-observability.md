# Mokosh Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a declarative, local-only VictoriaMetrics and Grafana monitoring stack to mokosh, with a public Grafana UI and native metrics from node exporter, Headscale, Miniflux, and Stalwart.

**Architecture:** `roles/observability/` is a single aggregated role composed from focused Nix modules. Application roles own their native metrics listeners and append typed scrape-job registrations; VictoriaMetrics consumes the aggregation without knowing application-specific endpoint details. Grafana is the only public component and is reverse-proxied by nginx.

**Tech Stack:** NixOS 26.05 modules; Prometheus node exporter; VictoriaMetrics 1.150.0; Grafana 13.0.7; nginx; Cloudflare DNSControl.

**Spec:** `docs/superpowers/specs/2026-09-19-mokosh-observability-design.md`

## Global Constraints

- Enable the stack only on mokosh.
- Configure VictoriaMetrics with `retentionPeriod = "30d"`; it retains at least 30 days and may over-retain at storage-partition boundaries. Scrape all jobs every `60s`.
- Bind every exporter, VictoriaMetrics, and Grafana to `127.0.0.1`; do not open firewall ports for them.
- Expose only Grafana at `https://grafana.uspenskiy.tech` through nginx and Cloudflare.
- Use only native application metrics: Headscale, Miniflux, and Stalwart. Do not introduce a third-party application exporter.
- Preserve source ownership: each application role owns its `metrics.enable` option, listener configuration, and scrape-job registration.
- Store Grafana credentials only in the locked, root-owned `/etc/nixos/secrets/grafana.env`; never place plaintext secrets in Nix or Git.
- Do not add alerts, uptime probes, logs, traces, remote write, federation, or a remote agent.

---

## File structure

| File | Responsibility |
| --- | --- |
| `roles/observability/default.nix` | Defines the single role gate, its public inputs, the internal typed scrape-job registry, and default enabling of source-owned metrics. |
| `roles/observability/node-exporter.nix` | Configures local host metrics and registers the `node` scrape job. |
| `roles/observability/victoria-metrics.nix` | Configures the VictoriaMetrics server and renders registered jobs as `scrape_configs`. |
| `roles/observability/grafana.nix` | Configures the local Grafana server, datasource, dashboard provisioning, secret environment file, nginx vhost, and Grafana self-scrape registration. |
| `roles/observability/dashboards/mokosh-overview.json` | Git-managed Grafana dashboard for host resources and scrape health. |
| `roles/vpn.nix` | Adds and implements `roles.vpn.metrics.enable` for Headscale. |
| `roles/reading/rss/miniflux.nix` | Adds and implements `roles.rss.metrics.enable` for Miniflux. |
| `roles/communication/mail.nix` | Adds and implements `roles.mail.metrics.enable` for Stalwart. |
| `machines/mokosh/default.nix` | Enables the role with the `uspenskiy.tech` base domain. |
| `dns/zones/uspenskiy-tech.nix` | Declares the public Grafana CNAME. |
| `secrets/unlocked/spec.txt` | Declares locked-file ownership and permissions for `grafana.env`. |

## Shared module interface

`roles/observability/default.nix` defines the following internal registration shape. It intentionally includes only data VictoriaMetrics needs to scrape a native endpoint.

```nix
roles.observability.scrapeJobs = mkOption {
  internal = true;
  default = [ ];
  type = types.listOf (types.submodule {
    options = {
      name = mkOption { type = types.str; };
      target = mkOption { type = types.str; };
      metricsPath = mkOption {
        type = types.str;
        default = "/metrics";
      };
      scheme = mkOption {
        type = types.enum [ "http" "https" ];
        default = "http";
      };
    };
  });
};
```

Every source module appends one job with `mkAfter`. `victoria-metrics.nix` transforms registrations into a `static_configs` target with `labels.host = "mokosh"`; application roles never hard-code a host label.

### Task 1: Add the observability role, node exporter, and VictoriaMetrics

**Files:**
- Create: `roles/observability/default.nix`
- Create: `roles/observability/node-exporter.nix`
- Create: `roles/observability/victoria-metrics.nix`
- Modify: `machines/mokosh/default.nix`

**Interfaces:**
- Consumes: `roles.observability.enable`, `roles.observability.baseDomain`, and the internal `roles.observability.scrapeJobs` list.
- Produces: a loopback node exporter, a loopback VictoriaMetrics server, and the job-registration interface consumed by source roles and Grafana.

- [ ] **Step 1: Create the role root and registry contract**

Create `roles/observability/default.nix` with the role gate and typed registry. Source defaults are added only in Task 2, after their owning roles define the nested options:

```nix
{ config, lib, ... }:

with lib;

let
  cfg = config.roles.observability;
  scrapeJobType = types.submodule {
    options = {
      name = mkOption { type = types.str; };
      target = mkOption { type = types.str; };
      metricsPath = mkOption {
        type = types.str;
        default = "/metrics";
      };
      scheme = mkOption {
        type = types.enum [ "http" "https" ];
        default = "http";
      };
    };
  };
in
{
  imports = [
    ./node-exporter.nix
    ./victoria-metrics.nix
  ];

  options.roles.observability = {
    enable = mkEnableOption "observability stack";
    baseDomain = mkOption { type = types.str; };
    scrapeJobs = mkOption {
      type = types.listOf scrapeJobType;
      default = [ ];
      internal = true;
      description = "Native Prometheus scrape targets registered by their owning roles.";
    };
  };

}
```

- [ ] **Step 2: Configure and register node exporter**

Create `roles/observability/node-exporter.nix`:

```nix
{ config, lib, ... }:

with lib;

let
  cfg = config.roles.observability;
in
{
  config = mkIf cfg.enable {
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      enabledCollectors = [ "systemd" ];
    };

    roles.observability.scrapeJobs = mkAfter [
      {
        name = "node";
        target = "127.0.0.1:9100";
      }
    ];
  };
}
```

- [ ] **Step 3: Configure and self-register VictoriaMetrics**

Create `roles/observability/victoria-metrics.nix`. Map every registry entry to one Prometheus-compatible job, explicitly emitting its path and scheme.

```nix
{ config, lib, ... }:

with lib;

let
  cfg = config.roles.observability;
  scrapeConfigs = map (job: {
    job_name = job.name;
    metrics_path = job.metricsPath;
    scheme = job.scheme;
    static_configs = [
      {
        targets = [ job.target ];
        labels.host = "mokosh";
      }
    ];
  }) cfg.scrapeJobs;
in
{
  config = mkIf cfg.enable {
    services.victoriametrics = {
      enable = true;
      listenAddress = "127.0.0.1:8428";
      retentionPeriod = "30d";
      prometheusConfig = {
        global.scrape_interval = "60s";
        scrape_configs = scrapeConfigs;
      };
    };

    roles.observability.scrapeJobs = mkAfter [
      {
        name = "victoriametrics";
        target = "127.0.0.1:8428";
      }
    ];
  };
}
```

- [ ] **Step 4: Enable the foundation on mokosh**

Add this block in `machines/mokosh/default.nix` under the `### Roles ###` heading, after `roles.hardened.enable = true;`:

```nix
  roles.observability = {
    enable = true;
    baseDomain = domainNames.secondary;
  };
```

Do this now so every following configuration evaluation exercises the enabled role, while Grafana remains absent until Task 3.

- [ ] **Step 5: Format and evaluate the isolated role changes**

Run:

```bash
nixfmt roles/observability/default.nix roles/observability/node-exporter.nix roles/observability/victoria-metrics.nix machines/mokosh/default.nix
make setup-dummy-secrets
nix eval --json 'path:.'#nixosConfigurations.mokosh.config.services.victoriametrics.prometheusConfig
```

Expected: evaluation succeeds and the JSON contains the `node` and `victoriametrics` jobs with 60-second global scraping, loopback targets, and a `host` label.

- [ ] **Step 6: Commit the stack foundation**

```bash
git add roles/observability/default.nix roles/observability/node-exporter.nix roles/observability/victoria-metrics.nix machines/mokosh/default.nix
git commit -m "feat(observability): add local metrics foundation"
```

### Task 2: Let application roles own their native metrics endpoints

**Files:**
- Modify: `roles/observability/default.nix`
- Modify: `roles/vpn.nix`
- Modify: `roles/reading/rss/miniflux.nix`
- Modify: `roles/communication/mail.nix`

**Interfaces:**
- Consumes: `roles.observability.scrapeJobs` from Task 1.
- Produces: `roles.vpn.metrics.enable`, `roles.rss.metrics.enable`, and `roles.mail.metrics.enable`; each configures its native listener and appends exactly one job when both the service and metrics are enabled.

- [ ] **Step 1: Add Headscale metrics to the VPN role**

In `roles/vpn.nix`, add this option alongside the existing VPN options:

```nix
metrics.enable = mkEnableOption "Headscale native Prometheus metrics";
```

Inside the existing `config = mkIf cfg.enable (mkMerge [ ... ])`, append this third merge member:

```nix
(mkIf cfg.metrics.enable {
  services.headscale.settings.metrics_listen_addr = "127.0.0.1:9090";

  roles.observability.scrapeJobs = mkAfter [
    {
      name = "headscale";
      target = "127.0.0.1:9090";
    }
  ];
})
```

- [ ] **Step 2: Add Miniflux metrics to the RSS role**

In `roles/reading/rss/miniflux.nix`, add this option under `options.roles.rss`:

```nix
metrics.enable = mkEnableOption "Miniflux native Prometheus metrics";
```

Import `optionalAttrs` from `lib` by using the existing `with lib;` scope. Extend the existing `services.miniflux.config` value after its ordinary attributes so the metric collector is enabled only when requested:

```nix
config = {
  LISTEN_ADDR = minifluxUrl;
  CLEANUP_FREQUENCY = 48;
  FETCHER_ALLOW_PRIVATE_NETWORKS = 1;
  HTTP_CLIENT_TIMEOUT = 60;
  ADMIN_USERNAME = "o__ni";
  CREATE_ADMIN = 1;
} // optionalAttrs cfg.metrics.enable {
  METRICS_COLLECTOR = 1;
  METRICS_ALLOWED_NETWORKS = "127.0.0.1/8";
  METRICS_REFRESH_INTERVAL = 60;
};
```

Add this sibling configuration inside the role's `mkIf cfg.enable` block:

```nix
roles.observability.scrapeJobs = mkIf cfg.metrics.enable (mkAfter [
  {
    name = "miniflux";
    target = "127.0.0.1:8200";
  }
]);
```

The scrape target is explicitly IPv4 loopback so it satisfies `METRICS_ALLOWED_NETWORKS` even when `localhost` resolves to IPv6 first. In the existing `services.nginx.virtualHosts."rss.${cfg.baseDomain}"` block, add this exact-match denial before its catch-all location so the public RSS vhost cannot forward the collector endpoint:

```nix
locations."= /metrics".return = "404";
```

Keep Miniflux's listener and ordinary nginx proxy unchanged.

- [ ] **Step 3: Add Stalwart metrics to the mail role**

In `roles/communication/mail.nix`, add this option under `options.roles.mail`:

```nix
metrics.enable = mkEnableOption "Stalwart native Prometheus metrics";
```

Extend the existing `services.stalwart.settings` value by merging this conditional attribute set after the normal static configuration:

```nix
// optionalAttrs cfg.metrics.enable {
  metrics.prometheus.enable = true;
}
```

This emits Stalwart's native, unauthenticated `/metrics/prometheus` handler only on the existing `127.0.0.1:10080` management listener. In the existing `services.nginx.virtualHosts.${mailHostname}` block, add this exact-match denial before its catch-all location so the public mail vhost cannot forward the endpoint:

```nix
locations."= /metrics/prometheus".return = "404";
```

Do not add a public metrics nginx location or a firewall rule.

Add this sibling configuration inside the existing `mkIf cfg.enable` block:

```nix
roles.observability.scrapeJobs = mkIf cfg.metrics.enable (mkAfter [
  {
    name = "stalwart";
    target = "127.0.0.1:10080";
    metricsPath = "/metrics/prometheus";
  }
]);
```

- [ ] **Step 4: Let observability enable the source-owned options by default**

After the `options` block in `roles/observability/default.nix`, add this `config` block:

```nix
  config = mkIf cfg.enable {
    roles.vpn.metrics.enable = mkDefault true;
    roles.rss.metrics.enable = mkDefault true;
    roles.mail.metrics.enable = mkDefault true;
  };
```

These are defaults, not forced values: a host may set any one of these nested options to `false` while retaining the rest of the stack.

- [ ] **Step 5: Format and evaluate all native target registrations**

Run:

```bash
nixfmt roles/observability/default.nix roles/vpn.nix roles/reading/rss/miniflux.nix roles/communication/mail.nix
nix eval --json 'path:.'#nixosConfigurations.mokosh.config.services.victoriametrics.prometheusConfig
```

Expected: evaluation succeeds and `scrape_configs` has exactly five jobs named `node`, `victoriametrics`, `headscale`, `miniflux`, and `stalwart`; every target is `127.0.0.1:<port>` and Stalwart uses `/metrics/prometheus`. Inspect the evaluated nginx virtual hosts to confirm the exact `/metrics` and `/metrics/prometheus` denials coexist with their catch-all application proxies.

- [ ] **Step 6: Commit the source-owned integrations**

```bash
git add roles/observability/default.nix roles/vpn.nix roles/reading/rss/miniflux.nix roles/communication/mail.nix
git commit -m "feat(observability): register native service metrics"
```

### Task 3: Add Grafana, the provisioned dashboard, and public route

**Files:**
- Modify: `roles/observability/default.nix`
- Create: `roles/observability/grafana.nix`
- Create: `roles/observability/dashboards/mokosh-overview.json`

**Interfaces:**
- Consumes: `roles.observability.enable`, `roles.observability.baseDomain`, and the local VictoriaMetrics endpoint from Task 1.
- Produces: Grafana on `127.0.0.1:3000`, a non-editable `VictoriaMetrics` datasource with UID `victoriametrics`, a provisioned `Mokosh Overview` dashboard with UID `mokosh-overview`, and the public nginx vhost.

- [ ] **Step 1: Import and configure Grafana**

In `roles/observability/default.nix`, add `./grafana.nix` to the existing `imports` list. Then create `roles/observability/grafana.nix` with a local listener, Grafana's native metrics endpoint, secret environment file, and declarative datasource:

```nix
{ config, lib, ... }:

with lib;

let
  cfg = config.roles.observability;
  hostname = "grafana.${cfg.baseDomain}";
in
{
  config = mkIf cfg.enable {
    services.grafana = {
      enable = true;
      settings = {
        server = {
          domain = hostname;
          root_url = "https://${hostname}/";
          enforce_domain = true;
        };
        security = {
          cookie_secure = true;
          cookie_samesite = "lax";
        };
        users.allow_sign_up = false;
        "auth.anonymous".enabled = false;
        metrics.enabled = true;
      };
      provision = {
        enable = true;
        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "VictoriaMetrics";
              uid = "victoriametrics";
              type = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:8428";
              isDefault = true;
              editable = false;
            }
          ];
        };
        dashboards.settings = {
          apiVersion = 1;
          providers = [
            {
              name = "mokosh";
              type = "file";
              disableDeletion = true;
              editable = false;
              options.path = ./dashboards;
            }
          ];
        };
      };
    };

    systemd.services.grafana.serviceConfig.EnvironmentFile = "/etc/nixos/secrets/grafana.env";

    roles.observability.scrapeJobs = mkAfter [
      {
        name = "grafana";
        target = "127.0.0.1:3000";
      }
    ];

    services.nginx.virtualHosts.${hostname} = {
      forceSSL = true;
      enableACME = false;
      sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";
      locations."= /metrics".return = "404";
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
        recommendedProxySettings = true;
      };
    };
  };
}
```

- [ ] **Step 2: Add the managed overview dashboard**

Create `roles/observability/dashboards/mokosh-overview.json` as a Grafana dashboard JSON document with `uid` `mokosh-overview`, title `Mokosh Overview`, datasource UID `victoriametrics`, a `$host` query variable using `label_values(up, host)`, refresh `1m`, and these exact PromQL target expressions:

| Panel title | PromQL expression |
| --- | --- |
| CPU utilization | `100 - (avg by (host) (rate(node_cpu_seconds_total{host="$host",mode="idle"}[$__rate_interval])) * 100)` |
| Load (1m) | `node_load1{host="$host"}` |
| Memory used | `100 * (1 - node_memory_MemAvailable_bytes{host="$host"} / node_memory_MemTotal_bytes{host="$host"})` |
| Swap used | `100 * (1 - node_memory_SwapFree_bytes{host="$host"} / node_memory_SwapTotal_bytes{host="$host"})` |
| Filesystem used | `100 * (1 - node_filesystem_avail_bytes{host="$host",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{host="$host",fstype!~"tmpfs|overlay"})` |
| Inodes used | `100 * (1 - node_filesystem_files_free{host="$host",fstype!~"tmpfs|overlay"} / node_filesystem_files{host="$host",fstype!~"tmpfs|overlay"})` |
| Network receive | `sum by (device) (rate(node_network_receive_bytes_total{host="$host",device!="lo"}[$__rate_interval])) * 8` |
| Network transmit | `sum by (device) (rate(node_network_transmit_bytes_total{host="$host",device!="lo"}[$__rate_interval])) * 8` |
| Selected systemd units | `node_systemd_unit_state{host="$host",state="active",name=~"(nginx|grafana|victoriametrics|headscale|stalwart(-mail)?|miniflux).*"}` |
| Scrape target state | `up{host="$host"}` |
| Scrape duration | `scrape_duration_seconds{host="$host"}` |
| Samples scraped | `scrape_samples_scraped{host="$host"}` |

Use unit `percent` and min/max `0`/`100` for the percentage panels; use `Bps` for network panels; use `seconds` for scrape duration. Use table or status-history visualization for `up` and the systemd state, and timeseries visualizations for all resource and scrape-rate panels. Set `schemaVersion` to `41`; do not import an external dashboard or add a plugin.

- [ ] **Step 3: Format and evaluate the Grafana configuration**

Run:

```bash
nixfmt roles/observability/grafana.nix
jq empty roles/observability/dashboards/mokosh-overview.json
nix eval --json 'path:.'#nixosConfigurations.mokosh.config.services.grafana.provision.datasources.settings
nix eval --json 'path:.'#nixosConfigurations.mokosh.config.services.victoriametrics.prometheusConfig
```

Expected: Grafana's datasource has UID `victoriametrics`, uses the loopback VictoriaMetrics URL, is non-editable, and the scrape configuration now includes the `grafana` job.

- [ ] **Step 4: Commit the Grafana service and dashboard**

```bash
git add roles/observability/default.nix roles/observability/grafana.nix roles/observability/dashboards/mokosh-overview.json
git commit -m "feat(observability): add grafana dashboard"
```

### Task 4: Enable mokosh, declare DNS and the secret contract, then verify

**Files:**
- Modify: `dns/zones/uspenskiy-tech.nix`
- Modify: `secrets/unlocked/spec.txt`

**Interfaces:**
- Consumes: the enabled mokosh role from Task 1 and Grafana's `EnvironmentFile` path from Task 3.
- Produces: a public `grafana.uspenskiy.tech` DNS route and an installable Grafana credential file contract.

- [ ] **Step 1: Declare the public DNS record**

Add this record to the `records` list in `dns/zones/uspenskiy-tech.nix`, adjacent to the other CNAMEs targeting mokosh:

```nix
    {
      type = "CNAME";
      name = "grafana";
      target = "mokosh.uspenskiy.tech.";
      proxied = true;
      ttl = "auto";
    }
```

- [ ] **Step 2: Declare and create the Grafana secret file safely**

Add this exact line to `secrets/unlocked/spec.txt`:

```text
mokosh:grafana.env:0400:root:root
```

On a workstation where locked secrets have been unlocked, create `secrets/unlocked/grafana.env` without printing it and do not stage it:

```bash
umask 077
{
  printf '%s\n' 'GF_SECURITY_ADMIN_USER=o__ni'
  printf 'GF_SECURITY_ADMIN_PASSWORD='
  openssl rand -base64 48 | tr -d '\n'
  printf '\nGF_SECURITY_SECRET_KEY='
  openssl rand -hex 32
} > secrets/unlocked/grafana.env
make lock-files
```

Confirm `git status --short` does not list `secrets/unlocked/grafana.env`. Stage the changed tracked encrypted archive `secrets/locked.tar.gpg` with `spec.txt`; never stage the plaintext environment file.

- [ ] **Step 3: Run formatting, DNS validation, and full flake checks**

Run:

```bash
nixfmt .
make setup-dummy-secrets
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --print-build-logs \
  ".#checks.${system}.dns-render" \
  ".#checks.${system}.dns-config" \
  ".#checks.${system}.dns-app-safety"
make check
nix build 'path:.#nixosConfigurations.mokosh.config.system.build.toplevel'
```

Expected: every command exits successfully. Do not apply DNS as part of this task; a human must review a future `make dns:plan` output before any apply.

- [ ] **Step 4: Commit the DNS declaration and secret contract**

```bash
git add dns/zones/uspenskiy-tech.nix secrets/unlocked/spec.txt secrets/locked.tar.gpg
git commit -m "feat(observability): publish grafana route"
```

- [ ] **Step 5: Perform post-deployment smoke checks on mokosh**

On mokosh, install the root-owned secret before the normal deployment; PID 1 can read it even though Grafana runs as the unprivileged `grafana` user. Then run:

```bash
make install-secrets
make switch
systemctl is-active prometheus-node-exporter.service victoriametrics.service grafana.service headscale.service miniflux.service stalwart.service
curl --fail --silent http://127.0.0.1:8428/-/healthy
curl --fail --silent http://127.0.0.1:9100/metrics >/dev/null
curl --fail --silent http://127.0.0.1:9090/metrics >/dev/null
curl --fail --silent http://127.0.0.1:8200/metrics >/dev/null
curl --fail --silent http://127.0.0.1:10080/metrics/prometheus >/dev/null
curl --fail --silent http://127.0.0.1:8428/api/v1/targets | jq -e '
  [.data.activeTargets[] | { job: .labels.job, health: .health }]
  | ((map(.job) | sort) == ["grafana", "headscale", "miniflux", "node", "stalwart", "victoriametrics"])
    and all(.[]; .health == "up")
'
```

The final `jq` command must return true; the targets endpoint responding alone is not sufficient. Then sign in at `https://grafana.uspenskiy.tech` as `o__ni`, verify that the `VictoriaMetrics` datasource is healthy, and open the provisioned `Mokosh Overview` dashboard. Confirm the public proxies do not disclose metrics:

```bash
test "$(curl --silent --output /dev/null --write-out '%{http_code}' https://rss.uspenskiy.tech/metrics)" = 404
test "$(curl --silent --output /dev/null --write-out '%{http_code}' https://mail.uspenskiy.su/metrics/prometheus)" = 404
test "$(curl --silent --output /dev/null --write-out '%{http_code}' https://grafana.uspenskiy.tech/metrics)" = 404
```

If DNS is ready to be reconciled, run `make dns:plan`, inspect the planned addition is only the Grafana CNAME, and have a human approve any later `make dns:apply`.
