# Tailnet Metrics Scraping for veles and buyan

**Status:** draft
**Date:** 2026-09-21

## Goal

Extend the observability stack on `mokosh` to scrape metrics from `veles` and
`buyan` over the existing Headscale tailnet, without exposing any scrape
endpoint to the public internet. The metrics answer three operational
questions about the proxy hosts:

1. which observed xray outbounds are alive and how much traffic each
   inbound/outbound carries;
2. how many connections fail to parse or connect, and how many status-200
   sessions terminate unusually quickly, at the nginx stream front door
   (SNI router);
3. where the kernel sees handshake/data delivery asymmetry — host-wide
   correlation signals for possible DPI interference (SYN or SYN-ACK
   retransmissions, stuck SYN_RECV, data retransmissions, timeouts).

This spec supersedes two explicit deferrals from earlier designs: "Do not
configure … MagicDNS" (2026-09-06 Headscale design) and "does not add … a
remote scrape agent" (2026-09-19 observability design).

## Scope

- Enable MagicDNS on Headscale with `base_domain = "ts"`; node names resolve
  as `<hostname>.ts` inside the tailnet only (`veles.ts`, `buyan.ts`,
  `mokosh.ts`). No public DNS records, no `dns.extra_records`, no pinned
  tailnet IPs.
- Enroll `mokosh`, `veles`, and `buyan` on the tailnet via
  `services.tailscale.authKeyFile` + `extraUpFlags = [ "--login-server=..." ]`.
  All three hosts share one reusable, explicitly expiring preauth key as an
  encrypted file secret; enrollment state makes subsequent rebuilds idempotent.
- Add `roles.observability.agent` — a node-side slice of the observability
  role: node_exporter bound to the wildcard address, firewalled to the
  `tailscale0` interface, `netstat` and textfile collectors enabled.
- Per-role collectors writing Prometheus textfiles (no new packages, no new
  flake inputs):
  - `roles.xray.metrics`: native xray `metrics` endpoint (expvar JSON on
    loopback) converted by a jq collector script into per-inbound/outbound
    traffic counters and observatory health gauges.
  - `roles.sni-router`: bounded-label JSON stream access log to journald,
    aggregated by a journal-cursor collector script into per-SNI session and
    byte counters plus a status-labelled duration histogram.
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

### Mokosh co-location decision and fallback

The initial implementation enrolls `mokosh` with the native NixOS Tailscale
service. This is the smallest deployment and keeps VictoriaMetrics scraping
directly over `tailscale0`, but Headscale documents running Headscale and a
Tailscale client on the same machine as unsupported, particularly when
MagicDNS or a traffic relay is involved. This deployment deliberately accepts
that supportability risk for the first rollout.

The risk is constrained: mokosh advertises no subnet routes or exit-node
function, the MagicDNS domain (`ts`) is separate from the public control-plane
domain, and `override_local_dns` remains false. Deployment must nevertheless
verify after every Headscale or Tailscale upgrade that the public Headscale
endpoint, embedded DERP/STUN, mokosh DNS resolution, and remote node scrapes
all remain healthy.

If native co-location causes DNS, routing, firewall, or DERP regressions, the
fallback is an isolated userspace Tailscale sidecar on mokosh:

- remove native `services.tailscale` enrollment from the host;
- run a `tailscaled --tun=userspace-networking` instance with its own state
  and socket plus `--outbound-http-proxy-listen=127.0.0.1:1055`;
- keep the local mokosh `node` scrape direct, and put remote agents in a
  `node-tailnet` scrape job with `proxy_url` set to that loopback proxy;
- enroll the sidecar with a fresh one-time key under a distinct node name.

The userspace proxy resolves MagicDNS from its network map without changing
mokosh's host routes or resolver. This fallback is a design contingency only;
it is intentionally excluded from the initial implementation plan.

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
shared key only when the backend reports `NeedsLogin`, so redeploys and
reboots are no-ops for an already-enrolled node. All three autoconnect units
restart on failure so a transiently unavailable control plane does not strand
initial enrollment. On mokosh the unit is also ordered after Headscale and
Nginx so the first auth-key submission cannot race the local endpoint. The
shared key is reusable for recovery while valid; after expiration or
revocation the operator must create a replacement, update the encrypted file
bundle, and redeploy the affected host(s).

DNS posture per host:

- `mokosh`: `extraSetFlags = [ "--accept-dns=true" ]` explicitly keeps
  MagicDNS enabled because it must resolve `*.ts` to scrape.
- `veles`, `buyan`: both initial `extraUpFlags` and persistent
  `extraSetFlags` carry `--accept-dns=false` — their resolvers stay exactly
  `1.1.1.1` as today.
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

`netstat` collector supplies host-wide TCP/UDP correlation signals:
`Tcp_RetransSegs`, `TcpExt_TCPSynRetrans`, `TcpExt_TCPTimeouts`,
`TcpExt_ListenDrops`, `TcpExt_TCPAbortOnTimeout`, and UDP error counters.
`TcpExt_TCPSynRetrans` includes retransmitted SYNs as well as SYN-ACKs, so it
cannot by itself distinguish failed outbound connects from clients that never
ACKed the proxy. Dashboards describe it as a handshake-retransmission signal,
not proof of server-side DPI interference.

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
(fields: bounded SNI label, `status`, `bytes_sent`, `bytes_received`,
`session_time`, `upstream_connect_time`) and
`access_log syslog:server=unix:/dev/log,tag=nginx-stream` in the server
block — the same journald pattern the http block already uses. A second nginx
`map` converts configured SNI values to themselves and every other value,
including an empty SNI, to `unknown`. Client-controlled SNI therefore cannot
create unbounded persistent Prometheus label cardinality. The collector and
log config activate only when the agent role is enabled on the host.
fail2ban's nginx jails read log files, not this tag, so they are unaffected.

A collector script runs on a 30s timer: `journalctl -t nginx-stream
--after-cursor=<state>` → jq aggregation → cumulative counters written to
`<textfileDir>/nginx-stream.prom`:

- `nginx_stream_sessions_total{sni=<sni>,status=<status>}`
- `nginx_stream_{sent,received}_bytes_total{sni=<sni>}`
- `nginx_stream_session_duration_seconds_{bucket,sum,count}` with `sni`,
  `status`, and fixed duration buckets.

State (journald cursor + running totals in one atomically replaced snapshot)
persists across restarts in `/var/lib/<collector>/`. If journal rotation
invalidates the cursor, the collector advances to the current end of the
journal and preserves its totals rather than replaying old sessions.

Nginx stream statuses are bounded to `200` (completed), `400` (client data
could not be parsed), `403` (forbidden), `500` (internal error), `502`
(upstream selection/connect failure, including exhausted connect attempts),
and `503` (service unavailable, such as a connection limit). Nginx records a
TCP proxy idle timeout as `200`, so status alone is not a timeout classifier.
Byte asymmetry (`sent` vs `received` per SNI), the rate of short status-200
sessions, and the status-specific duration distribution are correlation
signals for possible DPI interference alongside the host-wide kernel
counters.

### Dashboards

`roles/observability/dashboards/proxy-health.json` (provisioned like
`machines-overview.json`), with a `host` dashboard variable:

- TCP health: rates of `TcpExt_TCPSynRetrans` (labelled as SYN/SYN-ACK
  retransmissions), `TcpExt_TCPTimeouts`, `Tcp_RetransSegs`;
  `tcp_states{state="syn_recv"}`; `ListenDrops`; UDP errors.
- Stream sessions: `rate(nginx_stream_sessions_total)` by `sni` × `status`;
  sent vs received bytes per SNI; short status-200 session rate and duration
  quantiles from the histogram.
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
| `machines/mokosh/default.nix` | `services.tailscale`, local control-plane ordering, `agent.enable`, `remoteAgents` |
| `machines/veles/default.nix` | `services.tailscale`, `agent.enable`, `xray.metrics.enable`, mtproxy port |
| `machines/buyan/default.nix` | `services.tailscale`, `agent.enable`, `xray.metrics.enable` |
| `machines/nixpi/default.nix` | `extraSetFlags = [ "--accept-dns=false" ]` |
| `secrets/unlocked/spec.txt` | tracked wildcard installation entry for the shared reusable Tailscale key file |

## Operational Runbook

Key creation and bundle installation are manual steps because preauth keys
are control-plane database state and plaintext key material must not be
committed:

1. On `mokosh`, run `sudo headscale users list`, note the intended user's
   numeric ID, and use the existing reusable key if it is still valid.
   Otherwise create one with an explicit expiration, for example:
   `sudo headscale preauthkeys create --user <user-id> --expiration 24h --reusable=true --ephemeral=false`.
2. On a trusted configuration machine, run `make unlock`, place the reusable
   key at `secrets/unlocked/tailscale-auth-key`, verify the plaintext file is
   not staged, then run `make lock` so it is stored in encrypted
   `secrets/locked.tar.gpg`. Never commit the plaintext key or place it in
   `secrets.json`; remove the plaintext transfer copy after locking.
3. Deploy in order: `mokosh` → `veles` → `buyan`. On each host, run
   `make unlock`, `sudo make install-secrets`, and `make switch`. The wildcard
   manifest installs the same key as `/etc/nixos/secrets/tailscale-auth-key`
   with mode 0400. Complete enrollment before the key expires.
4. If a node loses its Tailscale state while the key is valid, reinstall the
   bundle secret and redeploy it. If the key expired or was revoked, create a
   replacement reusable key, update the encrypted bundle, and repeat the
   rollout.

Validation as each prerequisite becomes available:

- `tailscale status` on `mokosh` lists the nodes with `100.64.0.0/10`
  addresses.
- `getent hosts veles.ts` resolves on `mokosh` (and only via the tailnet
  resolver).
- The public Headscale endpoint and embedded DERP/STUN remain healthy after
  mokosh joins; `tailscale netcheck` does not reveal a routing or relay
  regression.
- From `mokosh`: `curl http://veles.ts:9100/metrics` returns node_exporter
  output containing `tcp_states` and fresh `node_textfile_mtime_seconds`
  entries for `tcp.prom`, `xray.prom`, and `nginx-stream.prom` after the
  collectors' first tick. `xray_` and `nginx_stream_` samples appear once the
  corresponding proxy paths have produced traffic.
- From a public host: 9100 on veles/buyan public IPs is not open.
- VM `vmui` targets page shows the `node` job targets up; Grafana
  `proxy-health` dashboard renders.
- `nix flake check` passes (dummy secrets).

## Risks

- **Unsupported Headscale/Tailscale co-location on mokosh**: the initial
  native-client approach is intentionally provisional. Any DNS, routing,
  firewall, DERP, or upgrade regression triggers the userspace-sidecar
  fallback documented above; local mokosh scraping remains loopback-based so
  disabling native Tailscale only removes remote targets.
- **Shared reusable enrollment key**: every enrolled host can use the same
  credential while it remains valid, so compromise of any host can allow
  additional node enrollment. Keep the key encrypted at rest, use an explicit
  expiration, and rotate/revoke it through Headscale when the enrollment
  window closes or compromise is suspected.
- **veles disables IPv6 globally** (`net.ipv6.conf.all.disable_ipv6 = 1`):
  MagicDNS still publishes an AAAA for `veles.ts`. Go's dual-stack dialer
  (happy eyeballs) is expected to fall back to IPv4; if scraping breaks,
  scope the sysctl to the public interface only so `tailscale0` keeps v6.
- **Harvester/scrape cadence**: healthy collectors run every 30s and VM
  scrapes every 60s. A failed collector leaves its last good textfile in
  place, so operators must use `node_textfile_mtime_seconds` and systemd unit
  status to distinguish stale data from a quiet proxy.
- **journald rotation gaps** can lose stream-log deltas. An invalid persisted
  cursor is advanced to the current journal end without replaying retained
  entries; cumulative counters then resume from their persisted totals.
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
