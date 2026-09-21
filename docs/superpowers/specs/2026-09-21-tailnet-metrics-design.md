# Tailnet Metrics Scraping for veles and buyan

**Status:** draft
**Date:** 2026-09-21

## Goal

Extend the observability stack on `mokosh` to scrape metrics from `veles` and
`buyan` over the existing Headscale tailnet, without exposing any scrape
endpoint to the public internet. The metrics answer three operational
questions about the proxy hosts:

1. which xray inbounds/outbounds are alive and how much traffic they carry;
2. how many connections fail, time out, or drop per inbound at the nginx
   stream front door (SNI router);
3. where the kernel sees handshake/data delivery asymmetry — the
   server-side fingerprint of DPI interference (SYN-ACK retransmissions,
   stuck SYN_RECV, data retransmissions, timeouts).

This spec supersedes two explicit deferrals from earlier designs: "Do not
configure … MagicDNS" (2026-09-06 Headscale design) and "does not add … a
remote scrape agent" (2026-09-19 observability design).

## Scope

- Enable MagicDNS on Headscale with `base_domain = "ts"`; node names resolve
  as `<hostname>.ts` inside the tailnet only (`veles.ts`, `buyan.ts`,
  `mokosh.ts`). No public DNS records, no `dns.extra_records`, no pinned
  tailnet IPs.
- Enroll `mokosh`, `veles`, and `buyan` on the tailnet declaratively via
  `services.tailscale.authKeyFile` + `extraUpFlags = [ "--login-server=..." ]`
  with a reusable preauth key distributed as a file secret.
- Add `roles.observability.agent` — a node-side slice of the observability
  role: node_exporter bound to the wildcard address, firewalled to the
  `tailscale0` interface, `netstat` and textfile collectors enabled.
- Per-role collectors writing Prometheus textfiles (no new packages, no new
  flake inputs):
  - `roles.xray.metrics`: native xray `metrics` endpoint (expvar JSON on
    loopback) converted by a jq collector script into per-inbound/outbound
    traffic counters and observatory health gauges.
  - `roles.sni-router`: JSON stream access log to journald, aggregated by a
    journal-cursor collector script into per-SNI session counters and byte
    totals.
  - `roles.observability.agent`: TCP state gauge (SYN_RECV et al.) from
    `/proc/net/tcp{,6}`.
- VictoriaMetrics on `mokosh` gains a central `remoteAgents` list rendering
  one unified `node` job with per-target `host` labels; the local `mokosh`
  target stays on loopback.
- Initial Grafana dashboard `proxy-health.json`.
- Move the veles mtproxy local backend port off 9100 to free the standard
  node_exporter port.

## Non-Goals

- No per-user xray counters (system-level inbound/outbound counters only).
- No xray error-log parsing; outbound liveness comes from observatory gauges.
- No nginx http-block exporter (`stub_status` is 7 near-useless counters and
  the http block is idle on veles/buyan; stream metrics cover nginx).
- No dashboards beyond the initial `proxy-health`; no alerting.
- No coverage for hysteria/QUIC beyond kernel UDP error counters.
- No changes to the public DNS zones; no Cloudflare records.
- No exit nodes, subnet routers, Tailscale SSH, ACL policy, or `nixpi`
  enrollment changes.

## Architecture

```
veles, buyan (agents)                         mokosh (server + agent)
┌──────────────────────────────────┐          ┌───────────────────────────────────┐
│ node_exporter :9100 (0.0.0.0)    │◀tailscale│ VictoriaMetrics :8428             │
│  collectors: systemd, netstat,   │  scrape  │  ├ local scrapeJobs (unchanged)   │
│  textfile directory              │          │  └ node job: loopback(mokosh) +   │
│ xray expvar :11111 (loopback)    │          │    remoteAgents → <host>.ts      │
│  └→ collector timer → xray.prom  │          │ Grafana + proxy-health dashboard  │
│ nginx stream JSON log → journald │          │ Headscale: magic_dns = true,      │
│  └→ collector timer → nginx-     │          │  base_domain = "ts"               │
│     stream.prom                  │          │ services.tailscale (authKeyFile)  │
│ /proc/net/tcp → tcp.prom         │          └───────────────────────────────────┘
└──────────────────────────────────┘
  firewall: 9100 open on interface tailscale0 only
```

### Control plane

Headscale on `mokosh` enables MagicDNS and sets `base_domain = "ts"`.
`override_local_dns` stays `false`, so clients treat the tailnet resolver as
additive. Headscale 0.28 does not validate `base_domain` shape; `.ts` is not
a delegated public TLD, so the two-label names (`veles.ts`) stay
tailnet-internal and cannot collide with public resolution.

MagicDNS names are the only names used: they follow the NixOS hostname, are
served automatically by the control plane, and require no records to
provision or maintain. Headscale assigns tailnet IPs sequentially at
enrollment and offers no declarative pinning; nothing in this design depends
on specific IPs.

### Enrollment

`mokosh`, `veles`, and `buyan` set:

```nix
services.tailscale = {
  enable = true;
  openFirewall = true;
  authKeyFile = "/etc/nixos/secrets/tailscale-auth-key";
  extraUpFlags = [ "--login-server=https://headscale.uspenskiy.tech" ];
};
```

The upstream `tailscaled-autoconnect` unit is idempotent: it presents the
key only when the backend reports `NeedsLogin`, so redeploys and reboots are
no-ops for an already-enrolled node.

DNS posture per host:

- `mokosh`: default `--accept-dns=true` — must resolve `*.ts` to scrape.
- `veles`, `buyan`: `extraUpFlags` also carries `--accept-dns=false` — their
  resolvers stay exactly `1.1.1.1` as today.
- `nixpi`: already enrolled; gains `extraSetFlags = [ "--accept-dns=false" ]`
  to pin its resolver against the newly-pushed MagicDNS config. No other
  change.

### Agent role

`roles.observability` splits into two switches:

- `roles.observability.enable` — full stack (VictoriaMetrics, Grafana);
  `mokosh` only. No longer implies exporters.
- `roles.observability.agent.enable` — node-side exporters; set on
  `mokosh`, `veles`, `buyan`.

The agent side configures:

- `services.prometheus.exporters.node` with `listenAddress = "0.0.0.0"`,
  `enabledCollectors = [ "systemd" "netstat" ]`, and
  `--collector.textfile.directory=<textfileDir>` via `extraFlags`.
- `networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 9100 ]`.
- `roles.observability.agent.textfileDir` (default
  `/var/lib/prometheus-node-exporter-textfiles`), created and owned for
  collector writes; files written mode 0644.
- A TCP-state collector (timer, 30s) emitting `tcp_states{state=...}`
  gauges from `/proc/net/tcp` and `/proc/net/tcp6`.

`netstat` collector supplies the kernel-level DPI signals:
`Tcp_RetransSegs`, `TcpExt_TCPSynRetrans` (SYN-ACK retransmissions — "we
answered, the client never ACKed"), `TcpExt_TCPTimeouts`,
`TcpExt_ListenDrops`, `TcpExt_TCPAbortOnTimeout`, and UDP error counters.

### Scrape-target list (central)

`roles.observability.remoteAgents` on `mokosh` is the single central list:

```nix
roles.observability.remoteAgents = [ { host = "veles"; } { host = "buyan"; } ];
```

Each entry is `{ host = <hostname>; port = 9100 by default }`.
VictoriaMetrics renders one `node` job whose static targets are:

- `127.0.0.1:<nodePort>` with `host = "mokosh"` (loopback — scraping
  survives a dead `tailscaled`), contributed by the local agent;
- `<host>.ts:<port>` with `host = <host>` for each remote agent.

Job names carry no hostname; identity lives in the `host` label. The
existing internal `scrapeJobs` registrations (victoriametrics, headscale,
miniflux, mail, vpn) are unchanged; the hard-coded `host = "mokosh"` label
becomes the job-registering host's `config.networking.hostName`.

### xray metrics

`roles.xray.metrics` (new `roles/network/xray/metrics.nix`, imported by the
xray coordinator) provides `enable` and `listen` (default
`127.0.0.1:11111`). When enabled and xray server mode is active it injects
into the rendered xray config:

```json
"metrics": { "listen": "127.0.0.1:11111" },
"stats": {},
"policy": { "system": {
  "statsInboundUplink": true, "statsInboundDownlink": true,
  "statsOutboundUplink": true, "statsOutboundDownlink": true
} }
```

No `policy.levels` user counters. The metrics endpoint is loopback-only. The
option asserts that `roles.observability.agent.enable` is set — without a
textfile consumer the collector would write to nowhere.

A collector script (writeShellApplication, jq + curl) runs on a 30s timer
and converts `/debug/vars` expvar JSON to `<textfileDir>/xray.prom`:

- `xray_inbound_{uplink,downlink}_bytes_total{inbound=<tag>}`
- `xray_outbound_{uplink,downlink}_bytes_total{outbound=<tag>}`
- `xray_observatory_alive{outbound=<tag>}` (0/1),
  `xray_observatory_delay_milliseconds{outbound=<tag>}` — present on hosts
  with balancers/observatory (veles), absent elsewhere.

### sni-router stream metrics

`roles.sni-router` adds, at stream scope, an escaped-JSON `log_format`
(fields: `ssl_preread_server_name`, `status`, `bytes_sent`,
`bytes_received`, `session_time`, `upstream_connect_time`) and
`access_log syslog:server=unix:/dev/log,tag=nginx-stream` in the server
block — the same journald pattern the http block already uses. The collector
and log config activate only when the agent role is enabled on the host.
fail2ban's nginx jails read log files, not this tag, so they are unaffected.

A collector script runs on a 30s timer: `journalctl -t nginx-stream
--after-cursor=<state>` → jq aggregation → cumulative counters written to
`<textfileDir>/nginx-stream.prom`:

- `nginx_stream_sessions_total{sni=<sni>,status=<status>}`
- `nginx_stream_{sent,received}_bytes_total{sni=<sni>}`
- `nginx_stream_session_seconds_total{sni=<sni>}`

State (journald cursor + running totals) persists across restarts in
`/var/lib/<collector>/`. Session statuses follow nginx stream semantics:
`200` completed, `400` client-side abort, `502` backend connect failure
(xray inbound dead), `504` upstream timeout. Byte asymmetry
(`sent` vs `received` per SNI) plus short `session_time` on status-200
sessions is the DPI interference fingerprint this exposes, alongside the
kernel counters.

### Dashboards

`roles/observability/dashboards/proxy-health.json` (provisioned like
`machines-overview.json`), with a `host` dashboard variable:

- TCP health: rates of `TcpExt_TCPSynRetrans`, `TcpExt_TCPTimeouts`,
  `Tcp_RetransSegs`; `tcp_states{state="synrecv"}`; `ListenDrops`; UDP
  errors.
- Stream sessions: `rate(nginx_stream_sessions_total)` by `sni` × `status`;
  sent vs received bytes per SNI; session duration distribution.
- Xray: in/out traffic rates per inbound/outbound; observatory delay and
  alive state per outbound.

### Port collision

veles `roles.mtproxy.port` moves `9100` → `9102`. The port is the loopback
backend behind sni-router, not the public MTProto endpoint (which is 443
via SNI routing), so no client impact. This frees 9100 for node_exporter
on all agents.

## Files Touched

| File | Change |
|---|---|
| `roles/vpn.nix` | `dns.magic_dns = true`, `tailnetDomain` option → `dns.base_domain` |
| `roles/observability/default.nix` | `agent` submodule (enable, textfileDir), `remoteAgents` option |
| `roles/observability/node-exporter.nix` | gate on agent, wildcard bind, netstat + textfile collectors, firewall, TCP-state collector |
| `roles/observability/victoria-metrics.nix` | unified `node` job from local agent + `remoteAgents`; host-label fix |
| `roles/observability/dashboards/proxy-health.json` | new |
| `roles/network/xray/metrics.nix` | new; imported by `xray/default.nix` |
| `roles/network/sni-router.nix` | stream JSON log + collector |
| `machines/mokosh/default.nix` | `services.tailscale`, `agent.enable`, `remoteAgents` |
| `machines/veles/default.nix` | `services.tailscale`, `agent.enable`, `xray.metrics.enable`, mtproxy port |
| `machines/buyan/default.nix` | `services.tailscale`, `agent.enable`, `xray.metrics.enable` |
| `machines/nixpi/default.nix` | `extraSetFlags = [ "--accept-dns=false" ]` |
| `secrets/unlocked/spec.txt` | `*:tailscale-auth-key:0400:root:root` |

## Operational Runbook

One-time manual steps (preauth keys are control-plane database state and
cannot be declared in Nix):

1. On `mokosh`: `headscale preauthkeys create --user <user> --reusable`
   (no expiry).
2. `make unlock`, add `secrets/unlocked/tailscale-auth-key`, extend
   `spec.txt`, `make lock`.

Deploy order:

1. `mokosh`: `make install-secrets` + deploy — Headscale starts MagicDNS;
   `mokosh` joins its own tailnet.
2. `veles`: secrets + deploy — joins, becomes scrape target.
3. `buyan`: secrets + deploy — joins, becomes scrape target.

Validation after each step:

- `tailscale status` on `mokosh` lists the nodes with `100.64.0.0/10`
  addresses.
- `getent hosts veles.ts` resolves on `mokosh` (and only via the tailnet
  resolver).
- From `mokosh`: `curl http://veles.ts:9100/metrics` returns node_exporter
  output containing `xray_`, `nginx_stream_`, and `tcp_states` series
  (after collectors' first tick).
- From a public host: 9100 on veles/buyan public IPs is filtered.
- VM `vmui` targets page shows the `node` job targets up; Grafana
  `proxy-health` dashboard renders.
- `nix flake check` passes (dummy secrets).

## Risks

- **veles disables IPv6 globally** (`net.ipv6.conf.all.disable_ipv6 = 1`):
  MagicDNS still publishes an AAAA for `veles.ts`. Go's dual-stack dialer
  (happy eyeballs) is expected to fall back to IPv4; if scraping breaks,
  scope the sysctl to the public interface only so `tailscale0` keeps v6.
- **Harvester/scrape cadence**: collectors run every 30s, VM scrapes every
  60s — a scrape never sees a file older than ~30s (gauges fresh, counters
  unaffected).
- **journald rotation gaps** lose in-flight stream-log deltas between
  collector runs; acceptable for failure-rate metrics. Counters resume
  from persisted totals.
- **Single-label base domain**: two-label `veles.ts` queries resolve as
  absolute names under default `ndots` settings; if a future host ships an
  unusual resolver, `tailnetDomain` is one option away from a longer name.
- **Central `remoteAgents` list**: forgetting to add a new agent host means
  it exports but is never scraped; the dashboard's absence of a `host`
  series is the signal.

## Testing

No automated tests exist in this repository; validation is `nix flake
check` plus the manual runbook above. The collector scripts are
`writeShellApplication` units whose jq transforms can be exercised locally
against fixture JSON before deploy.
