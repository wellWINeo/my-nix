# Tailnet Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scrape node/nginx/xray metrics from `veles` and `buyan` on the mokosh VictoriaMetrics over the Headscale tailnet, with per-SNI failure/duration metrics and host-wide TCP correlation signals for possible DPI interference.

**Architecture:** MagicDNS provides `<hostname>.ts` names inside the tailnet (no records, no pinned IPs). Mokosh joins natively and VictoriaMetrics scrapes the remote agents directly over `tailscale0`. A new `roles.observability.agent` slice runs node_exporter (wildcard bind, firewalled to `tailscale0`, netstat + textfile collectors) on mokosh/veles/buyan. Role-owned collector scripts (xray expvar→textfile, bounded nginx stream journald log→textfile, TCP-state gauge) write Prometheus textfiles; VictoriaMetrics scrapes a unified `node` job built from a central `remoteAgents` list. Each newly enrolled node uses its own one-time, explicitly expiring preauth key supplied through `authKeyFile`.

**Tech Stack:** nixos-25.11 flake inputs with host state version 26.05, Headscale 0.28.0, Tailscale 1.98.10 (`services.tailscale`), VictoriaMetrics 1.150.0, node_exporter 1.11.1, xray 26.3.27, Grafana v2 dashboard provisioning, and `writeShellApplication` + jq collectors.

**Spec:** `docs/superpowers/specs/2026-09-21-tailnet-metrics-design.md` — the plan argues from the spec; executors read both.

## Global Constraints

- No new packages, no new flake inputs, no custom derivations — everything from stock nixpkgs.
- Scrape endpoints must never be reachable from the public internet: node_exporter binds `0.0.0.0` but port 9100 is opened **only** on interface `tailscale0`. Xray expvar endpoint stays on loopback.
- No public DNS changes; no `dns.extra_records`; MagicDNS names are `<hostname>.ts`.
- Each preauth key flows only as a host-specific file secret (`/etc/nixos/secrets/tailscale-auth-key-<hostname>`, mode 0400 root:root), never through `secrets.json`, the nix store, `locked.tar.gpg`, or any other tracked artifact. Keys are one-time and created with an explicit 24-hour enrollment window.
- Collectors run on 30s timers; VM scrape interval stays 60s.
- Job names carry no hostnames — identity is the `host` label.
- Format every touched Nix file with `nixfmt` before committing.
- Validate with `nix flake check 'path:.' --all-systems` (via `make check`) after dummy secrets are set up.
- Run the listed commit steps only when the user has explicitly requested commits; otherwise leave validated changes uncommitted. Any commit uses a plain message with no attribution trailers (repo AGENTS.md).
- All paths are relative to the worktree root `.worktrees/tailnet-metrics/`.

---

### Task 0: Worktree verification setup

**Files:**
- Create (untracked, never committed): `secrets/secrets.json`

**Interfaces:**
- Produces: an evaluable flake for all later `nix eval` / `make check` steps.

- [ ] **Step 1: Create dummy secrets**

```bash
make setup-dummy-secrets
```

- [ ] **Step 2: Verify the flake evaluates before any changes**

Run: `nix flake check 'path:.' --all-systems`
Expected: PASS (same as CI on main). If this fails before any change, stop and report.

---

### Task 1: Headscale MagicDNS

**Files:**
- Modify: `roles/vpn.nix`

**Interfaces:**
- Produces: `roles.vpn.tailnetDomain` (types.str, default `"ts"`) — consumed by Task 2 for building remote scrape addresses; sets `dns.magic_dns = true`, `dns.base_domain = cfg.tailnetDomain`. `override_local_dns` stays `false`.

- [ ] **Step 1: Add the option**

In `roles/vpn.nix`, extend `options.roles.vpn`:

```nix
    tailnetDomain = mkOption {
      type = types.str;
      default = "ts";
      description = "MagicDNS base domain; tailnet names are <hostname>.<tailnetDomain>";
    };
```

- [ ] **Step 2: Enable MagicDNS in the headscale settings**

Replace the `dns` block inside `services.headscale.settings`:

```nix
          dns = {
            magic_dns = true;
            base_domain = cfg.tailnetDomain;
            override_local_dns = false;
          };
```

- [ ] **Step 3: Format and spot-eval**

```bash
nixfmt roles/vpn.nix
nix eval path:.#nixosConfigurations.mokosh.config.services.headscale.settings.dns --json
```

Expected: `{"base_domain":"ts","magic_dns":true,"override_local_dns":false}`

- [ ] **Step 4: Commit**

```bash
git add roles/vpn.nix
git commit -m "feat(vpn): enable Headscale MagicDNS with ts base domain"
```

---

### Task 2: Observability agent/server split and unified node job

**Files:**
- Modify: `roles/observability/default.nix`
- Modify: `roles/observability/node-exporter.nix` (full rewrite)
- Modify: `roles/observability/victoria-metrics.nix`

**Interfaces:**
- Consumes: `roles.vpn.tailnetDomain` (Task 1).
- Produces:
  - `roles.observability.agent.enable` (bool, default false)
  - `roles.observability.agent.textfileDir` (str, default `/var/lib/prometheus-node-exporter-textfiles`) — consumed by Tasks 3 and 4
  - `roles.observability.remoteAgents` — list of `{ host = str; port = port (default 9100) }`
  - `scrapeJobType.host` (str, default `config.networking.hostName`)
  - Behavior: VM renders a single `node` job: loopback target when the VM host itself has `agent.enable`, plus `<host>.<tailnetDomain>:<port>` per remoteAgent, each with a `host` label. node-exporter no longer registers a `scrapeJobs` entry.

- [ ] **Step 1: Options in `roles/observability/default.nix`**

Extend `options.roles.observability` (keep the existing `enable`, `baseDomain`, `scrapeJobs`, and the `config` block unchanged):

```nix
    agent = {
      enable = mkEnableOption "node-side metrics agent (exporters + textfile collectors)";

      textfileDir = mkOption {
        type = types.str;
        default = "/var/lib/prometheus-node-exporter-textfiles";
        description = "Directory harvested by node_exporter's textfile collector";
      };
    };

    remoteAgents = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            host = mkOption {
              type = types.str;
              description = "Hostname label; also the MagicDNS name prefix (<host>.<tailnetDomain>)";
            };
            port = mkOption {
              type = types.port;
              default = 9100;
              description = "node_exporter port on the agent";
            };
          };
        }
      );
      default = [ ];
      description = "Tailnet hosts scraped by this VictoriaMetrics via the node job";
    };
```

Also add `host` to `scrapeJobType`:

```nix
      host = mkOption {
        type = types.str;
        default = config.networking.hostName;
        description = "Host label for this job's targets";
      };
```

- [ ] **Step 2: Rewrite `roles/observability/node-exporter.nix`**

Replace the entire file with:

```nix
{ config, lib, pkgs, ... }:

with lib;

let
  agent = config.roles.observability.agent;

  tcpStateCollector = pkgs.writeShellApplication {
    name = "tcp-state-collector";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      set -euo pipefail
      dir="''${1:-${agent.textfileDir}}"
      tmp="$(mktemp -p "$dir")"
      trap 'rm -f "$tmp"' EXIT

      # socket state hex codes from /proc/net/tcp{,6}
      declare -A NAMES=(
        [01]=established [02]=syn_sent [03]=syn_recv [04]=fin_wait1
        [05]=fin_wait2 [06]=time_wait [07]=close [08]=close_wait
        [09]=last_ack [0A]=listen [0B]=closing
      )
      declare -A COUNT

      while read -r st; do
        st="''${st^^}"
        if [ -n "''${NAMES[$st]:-}" ]; then
          COUNT[$st]=$(( ''${COUNT[$st]:-0} + 1 ))
        fi
      done < <(awk 'NR>1 { print $4 }' /proc/net/tcp /proc/net/tcp6 2>/dev/null)

      {
        echo "# HELP tcp_states Number of TCP sockets currently in each state."
        echo "# TYPE tcp_states gauge"
        for s in "''${!NAMES[@]}"; do
          echo "tcp_states{state=\"''${NAMES[$s]}\"} ''${COUNT[$s]:-0}"
        done
      } > "$tmp"
      chmod 0644 "$tmp"
      mv "$tmp" "$dir/tcp.prom"
    '';
  };
in
{
  config = mkIf agent.enable {
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "0.0.0.0";
      enabledCollectors = [
        "systemd"
        "netstat"
      ];
      extraFlags = [ "--collector.textfile.directory=${agent.textfileDir}" ];
    };

    # metrics port reachable only from the tailnet
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
      config.services.prometheus.exporters.node.port
    ];

    systemd.tmpfiles.rules = [ "d ${agent.textfileDir} 0755 root root -" ];

    systemd.services.tcp-state-collector = {
      description = "TCP state gauge textfile collector";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${tcpStateCollector}/bin/tcp-state-collector ${agent.textfileDir}";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ agent.textfileDir ];
      };
    };

    systemd.timers.tcp-state-collector = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "30s";
        AccuracySec = "1s";
        Unit = "tcp-state-collector.service";
      };
    };
  };
}
```

Note: this removes the previous `roles.observability.scrapeJobs` registration of the local `node` job — Task 2 Step 3 re-adds it centrally.

- [ ] **Step 3: Unified node job in `roles/observability/victoria-metrics.nix`**

Replace the `let` and `config` blocks so the file reads:

```nix
{ config, lib, ... }:

with lib;

let
  cfg = config.roles.observability;

  nodeStaticConfigs =
    (optional config.roles.observability.agent.enable {
      targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
      labels.host = config.networking.hostName;
    })
    ++ map (a: {
      targets = [ "${a.host}.${config.roles.vpn.tailnetDomain}:${toString a.port}" ];
      labels.host = a.host;
    }) cfg.remoteAgents;

  scrapeConfigs =
    (optional (nodeStaticConfigs != [ ]) {
      job_name = "node";
      static_configs = nodeStaticConfigs;
    })
    ++ map (job: {
      job_name = job.name;
      metrics_path = job.metricsPath;
      scheme = job.scheme;
      static_configs = [
        {
          targets = [ job.target ];
          labels.host = job.host;
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

- [ ] **Step 4: Format and evaluate**

```bash
nixfmt roles/observability/default.nix roles/observability/node-exporter.nix roles/observability/victoria-metrics.nix
nix eval path:.#nixosConfigurations.mokosh.config.services.victoriametrics.prometheusConfig.scrape_configs --json | jq '.[].job_name'
```

Expected: no `node` job yet (it appears in Task 5 once `agent.enable`/`remoteAgents` are wired); the list contains the pre-existing `victoriametrics`, `headscale`, `grafana`, miniflux/mail/vpn jobs, all labeled `host = "mokosh"`.

- [ ] **Step 5: Flake check**

Run: `nix flake check 'path:.' --all-systems`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add roles/observability/
git commit -m "feat(observability): agent/server split with unified node job"
```

---

### Task 3: xray expvar metrics + textfile collector

**Files:**
- Create: `roles/network/xray/metrics.nix`
- Modify: `roles/network/xray/default.nix`

**Interfaces:**
- Consumes: `roles.observability.agent.enable` (asserted), `roles.observability.agent.textfileDir`.
- Produces: `roles.xray.metrics.enable` (bool), `roles.xray.metrics.listen` (str, default `127.0.0.1:11111`), internal `roles.xray._extraConfig` (attrs merged into the rendered xray config root). Metrics emitted: `xray_{inbound,outbound}_{uplink,downlink}_bytes_total`, `xray_observatory_alive`, `xray_observatory_delay_milliseconds`.

- [ ] **Step 1: `_extraConfig` hook in `roles/network/xray/default.nix`**

Add to `options.roles.xray` (next to `_serverConfig`):

```nix
    _extraConfig = mkOption {
      type = types.attrs;
      internal = true;
      default = { };
      description = "Extra top-level config keys merged into the xray config";
    };
```

Change `xrayConfigTemplate` to merge it last:

```nix
  xrayConfigTemplate =
    xrayConfigBase
    // (optionalAttrs hasBalancers {
      observatory = {
        subjectSelector = [ "relay-" ];
        probeURL = "https://www.google.com/generate_204";
        probeInterval = "60s";
      };
    })
    // cfg._extraConfig;
```

- [ ] **Step 2: Create `roles/network/xray/metrics.nix`**

```nix
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.roles.xray.metrics;

  collector = pkgs.writeShellApplication {
    name = "xray-metrics-collector";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      set -euo pipefail
      listen="''${1:-${cfg.listen}}"
      dir="''${2:-${config.roles.observability.agent.textfileDir}}"
      data="$(mktemp)"
      out="$(mktemp -p "$dir")"
      trap 'rm -f "$data" "$out"' EXIT

      curl -fsS --max-time 10 "http://$listen/debug/vars" > "$data"

      {
        echo "# HELP xray_inbound_uplink_bytes_total Cumulative bytes received by xray from clients, per inbound."
        echo "# TYPE xray_inbound_uplink_bytes_total counter"
        jq -r '.stats.inbound // {} | to_entries[] | "xray_inbound_uplink_bytes_total{inbound=\"\(.key)\"} \(.value.uplink // 0)"' "$data"
        echo "# HELP xray_inbound_downlink_bytes_total Cumulative bytes sent by xray to clients, per inbound."
        echo "# TYPE xray_inbound_downlink_bytes_total counter"
        jq -r '.stats.inbound // {} | to_entries[] | "xray_inbound_downlink_bytes_total{inbound=\"\(.key)\"} \(.value.downlink // 0)"' "$data"
        echo "# HELP xray_outbound_uplink_bytes_total Cumulative bytes sent by xray to upstreams, per outbound."
        echo "# TYPE xray_outbound_uplink_bytes_total counter"
        jq -r '.stats.outbound // {} | to_entries[] | "xray_outbound_uplink_bytes_total{outbound=\"\(.key)\"} \(.value.uplink // 0)"' "$data"
        echo "# HELP xray_outbound_downlink_bytes_total Cumulative bytes received by xray from upstreams, per outbound."
        echo "# TYPE xray_outbound_downlink_bytes_total counter"
        jq -r '.stats.outbound // {} | to_entries[] | "xray_outbound_downlink_bytes_total{outbound=\"\(.key)\"} \(.value.downlink // 0)"' "$data"
        echo "# HELP xray_observatory_alive Whether the observatory considers this outbound alive (0/1)."
        echo "# TYPE xray_observatory_alive gauge"
        # protobuf JSON omits false scalar fields, so a missing .alive is 0.
        jq -r '.observatory // {} | to_entries[] | "xray_observatory_alive{outbound=\"\(.key)\"} \(if (.value.alive // false) then 1 else 0 end)"' "$data"
        echo "# HELP xray_observatory_delay_milliseconds Last observatory probe latency per outbound."
        echo "# TYPE xray_observatory_delay_milliseconds gauge"
        jq -r '.observatory // {} | to_entries[] | select(.value.delay != null) | "xray_observatory_delay_milliseconds{outbound=\"\(.key)\"} \(.value.delay)"' "$data"
      } > "$out"
      chmod 0644 "$out"
      mv "$out" "$dir/xray.prom"
    '';
  };
in
{
  options.roles.xray.metrics = {
    enable = mkEnableOption "xray expvar metrics and textfile collector";

    listen = mkOption {
      type = types.str;
      default = "127.0.0.1:11111";
      description = "Xray metrics (expvar) listen address";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.roles.xray.enable && config.roles.xray.server.enable;
        message = "roles.xray.metrics requires roles.xray server mode";
      }
      {
        assertion = config.roles.observability.agent.enable;
        message = "roles.xray.metrics requires roles.observability.agent.enable (textfile consumer missing)";
      }
    ];

    roles.xray._extraConfig = {
      metrics.listen = cfg.listen;
      stats = { };
      policy.system = {
        statsInboundUplink = true;
        statsInboundDownlink = true;
        statsOutboundUplink = true;
        statsOutboundDownlink = true;
      };
    };

    systemd.services.xray-metrics-collector = {
      description = "Xray expvar to textfile collector";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${collector}/bin/xray-metrics-collector ${cfg.listen} ${config.roles.observability.agent.textfileDir}";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ config.roles.observability.agent.textfileDir ];
      };
    };

    systemd.timers.xray-metrics-collector = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "30s";
        AccuracySec = "1s";
        Unit = "xray-metrics-collector.service";
      };
    };
  };
}
```

Add the import in `roles/network/xray/default.nix` `imports` list:

```nix
  imports = [
    ./server.nix
    ./client.nix
    ./relay.nix
    ./subscriptions.nix
    ./metrics.nix
    ../sni-router.nix
  ];
```

- [ ] **Step 3: Validate the jq transforms against a fixture**

```bash
cat > /tmp/xray-vars.json <<'EOF'
{"cmdline":["xray"],"memstats":{},"stats":{
  "inbound":{"vless-tcp-in":{"downlink":74460,"uplink":10231}},
  "outbound":{"relay-tcp-out":{"downlink":0,"uplink":5512},"direct":{"downlink":977,"uplink":32}},
  "user":{}},
 "observatory":{"relay-tcp-out":{"alive":true,"delay":782,"last_seen_time":1648477189},
                  "relay-grpc-out":{"last_error_reason":"probe failed"}}}
EOF
jq -r '.stats.inbound // {} | to_entries[] | "xray_inbound_uplink_bytes_total{inbound=\"\(.key)\"} \(.value.uplink // 0)"' /tmp/xray-vars.json
jq -r '.observatory // {} | to_entries[] | "xray_observatory_alive{outbound=\"\(.key)\"} \(if (.value.alive // false) then 1 else 0 end)"' /tmp/xray-vars.json
```

Expected output lines:
`xray_inbound_uplink_bytes_total{inbound="vless-tcp-in"} 10231`
`xray_observatory_alive{outbound="relay-tcp-out"} 1`
`xray_observatory_alive{outbound="relay-grpc-out"} 0`

- [ ] **Step 4: Format, evaluate, check**

```bash
nixfmt roles/network/xray/metrics.nix roles/network/xray/default.nix
nix eval path:.#nixosConfigurations.veles.config.roles.xray.metrics --json
nix flake check 'path:.' --all-systems
```

Expected: `{"enable":false,"listen":"127.0.0.1:11111"}` then PASS.

- [ ] **Step 5: Commit**

```bash
git add roles/network/xray/
git commit -m "feat(xray): expvar metrics option with textfile collector"
```

---

### Task 4: sni-router stream session metrics

**Files:**
- Modify: `roles/network/sni-router.nix`

**Interfaces:**
- Consumes: `roles.observability.agent.enable`, `roles.observability.agent.textfileDir`.
- Produces: bounded-label JSON stream access log tagged `nginx-stream` in journald; textfile metrics `nginx_stream_sessions_total{sni,status}`, `nginx_stream_{sent,received}_bytes_total{sni}`, and `nginx_stream_session_duration_seconds_{bucket,sum,count}{sni,status}`.

- [ ] **Step 1: Extend the module**

Change the module arguments to include `pkgs`:

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
```

Inside `let`, after `defaultBackend`, add:

```nix
  metricsEnabled = cfg.enable && config.roles.observability.agent.enable;

  streamCollector = pkgs.writeShellApplication {
    name = "nginx-stream-collector";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gawk
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail
      dir="${config.roles.observability.agent.textfileDir}"
      state="/var/lib/nginx-stream-collector"
      mkdir -p "$state"
      cursor=""

      # Fixed cumulative duration buckets in milliseconds.
      bucketMs=(100 500 1000 5000 30000 120000)
      bucketLe=(0.1 0.5 1 5 30 120)
      declare -A SESS SENT RECV DUR_SUM DUR_BUCKET
      if [ -f "$state/totals" ]; then
        while IFS=$'\t' read -r kind a b c d; do
          case "$kind" in
            c) cursor="$a" ;;
            s) SESS["$a|$b"]="''${c:-0}" ;;
            y) SENT["$a"]="''${b:-0}"; RECV["$a"]="''${c:-0}" ;;
            d) DUR_SUM["$a|$b"]="''${c:-0}" ;;
            b) DUR_BUCKET["$a|$b|$c"]="''${d:-0}" ;;
          esac
        done < "$state/totals"
      fi

      raw="$(mktemp)"
      events="$(mktemp)"
      journal_error="$(mktemp)"
      trap 'rm -f "$raw" "$events" "$journal_error"' EXIT
      if [ -n "$cursor" ]; then
        if ! LC_ALL=C journalctl -t nginx-stream -o json --after-cursor "$cursor" > "$raw" 2> "$journal_error"; then
          error="$(<"$journal_error")"
          if [[ "$error" != *"Failed to seek to cursor"* ]]; then
            printf '%s\n' "$error" >&2
            exit 1
          fi

          # A vacuumed cursor cannot be replayed safely without double-counting
          # retained sessions. Drop the unavailable gap and resume at journal end.
          cursor_line="$(journalctl --no-pager -n 0 --show-cursor | tail -n 1)"
          if [[ "$cursor_line" == "-- cursor: "* ]]; then
            cursor="''${cursor_line#-- cursor: }"
          else
            cursor=""
          fi
          : > "$raw"
          echo "nginx-stream journal cursor is stale; advanced to current journal end" >&2
        fi
      else
        journalctl -t nginx-stream -o json > "$raw"
      fi
      new_cursor="$(tail -n 1 "$raw" | jq -r '.__CURSOR // empty')"
      [ -n "$new_cursor" ] && cursor="$new_cursor"

      jq -r '
        .MESSAGE | fromjson |
        [ (.sni // "unknown"), (.status | tostring), (.sent | tostring), (.recv | tostring),
          (((.time | tonumber? // 0) * 1000) | round | tostring) ] | @tsv
      ' "$raw" > "$events"

      while IFS=$'\t' read -r sni status sent recv ms; do
        key="$sni|$status"
        SESS["$key"]=$(( ''${SESS["$key"]:-0} + 1 ))
        SENT["$sni"]=$(( ''${SENT["$sni"]:-0} + sent ))
        RECV["$sni"]=$(( ''${RECV["$sni"]:-0} + recv ))
        DUR_SUM["$key"]=$(( ''${DUR_SUM["$key"]:-0} + ms ))
        for le_ms in "''${bucketMs[@]}"; do
          if (( ms <= le_ms )); then
            bucket_key="$key|$le_ms"
            DUR_BUCKET["$bucket_key"]=$(( ''${DUR_BUCKET["$bucket_key"]:-0} + 1 ))
          fi
        done
      done < "$events"

      totals_tmp="$(mktemp "$state/totals.XXXXXX")"
      {
        printf 'c\t%s\t-\t-\t-\n' "$cursor"
        for k in "''${!SESS[@]}"; do
          IFS='|' read -r s st <<< "$k"
          printf 's\t%s\t%s\t%s\t-\n' "$s" "$st" "''${SESS[$k]}"
        done
        for s in "''${!SENT[@]}"; do
          printf 'y\t%s\t%s\t%s\t-\n' "$s" "''${SENT[$s]}" "''${RECV[$s]:-0}"
        done
        for k in "''${!DUR_SUM[@]}"; do
          IFS='|' read -r s st <<< "$k"
          printf 'd\t%s\t%s\t%s\t-\n' "$s" "$st" "''${DUR_SUM[$k]}"
        done
        for k in "''${!DUR_BUCKET[@]}"; do
          IFS='|' read -r s st le_ms <<< "$k"
          printf 'b\t%s\t%s\t%s\t%s\n' "$s" "$st" "$le_ms" "''${DUR_BUCKET[$k]}"
        done
      } > "$totals_tmp"
      mv "$totals_tmp" "$state/totals"

      out="$(mktemp -p "$dir")"
      {
        echo "# HELP nginx_stream_sessions_total Completed stream sessions per bounded SNI label and status."
        echo "# TYPE nginx_stream_sessions_total counter"
        for k in "''${!SESS[@]}"; do
          IFS='|' read -r s st <<< "$k"
          echo "nginx_stream_sessions_total{sni=\"$s\",status=\"$st\"} ''${SESS[$k]}"
        done
        echo "# HELP nginx_stream_sent_bytes_total Bytes sent to clients per bounded SNI label."
        echo "# TYPE nginx_stream_sent_bytes_total counter"
        for s in "''${!SENT[@]}"; do
          echo "nginx_stream_sent_bytes_total{sni=\"$s\"} ''${SENT[$s]}"
        done
        echo "# HELP nginx_stream_received_bytes_total Bytes received from clients per bounded SNI label."
        echo "# TYPE nginx_stream_received_bytes_total counter"
        for s in "''${!RECV[@]}"; do
          echo "nginx_stream_received_bytes_total{sni=\"$s\"} ''${RECV[$s]}"
        done
        echo "# HELP nginx_stream_session_duration_seconds Stream session duration by bounded SNI label and status."
        echo "# TYPE nginx_stream_session_duration_seconds histogram"
        for k in "''${!SESS[@]}"; do
          IFS='|' read -r s st <<< "$k"
          for i in "''${!bucketMs[@]}"; do
            le_ms="''${bucketMs[$i]}"
            le="''${bucketLe[$i]}"
            bucket_key="$k|$le_ms"
            echo "nginx_stream_session_duration_seconds_bucket{sni=\"$s\",status=\"$st\",le=\"$le\"} ''${DUR_BUCKET[$bucket_key]:-0}"
          done
          echo "nginx_stream_session_duration_seconds_bucket{sni=\"$s\",status=\"$st\",le=\"+Inf\"} ''${SESS[$k]}"
          seconds="$(awk -v ms="''${DUR_SUM[$k]:-0}" 'BEGIN { printf "%.3f", ms / 1000 }')"
          echo "nginx_stream_session_duration_seconds_sum{sni=\"$s\",status=\"$st\"} $seconds"
          echo "nginx_stream_session_duration_seconds_count{sni=\"$s\",status=\"$st\"} ''${SESS[$k]}"
        done
      } > "$out"
      chmod 0644 "$out"
      mv "$out" "$dir/nginx-stream.prom"
    '';
  };
```

In `config`, wrap the existing block in `mkMerge` and weave the bounded-label `map`, `log_format`, and `access_log` directives **into the existing `streamConfig` string** via `optionalString metricsEnabled`. The second map preserves configured SNI values and maps all client-controlled alternatives, including empty SNI, to the single `unknown` series. Nginx requires `log_format` to appear *before* the `server{}` block whose `access_log` references it, so these directives must be generated inside the existing string, never appended as a second `streamConfig` assignment (a concatenated assignment lands after the server block and `nginx -t` fails with `unknown log format`). The final structure:

```nix
  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.entries != [ ];
          message = "roles.sni-router requires at least one entry";
        }
      ];

      services.nginx = {
        enable = true;
        streamConfig = ''
          map $ssl_preread_server_name $sni_backend {
          ${
            lib.concatMapStrings (e: "    ${e.sni}  ${e.backend};\n") cfg.entries
          }    default  ${defaultBackend};
          }

          ${lib.optionalString metricsEnabled ''
            map $ssl_preread_server_name $metrics_sni {
            ${
              lib.concatMapStrings (e: "    ${e.sni}  ${e.sni};\n") cfg.entries
            }    default  unknown;
            }

            log_format metrics_json escape=json '{"sni":"$metrics_sni","status":$status,"sent":$bytes_sent,"recv":$bytes_received,"time":"$session_time","uct":"$upstream_connect_time"}';
          ''}

          server {
            listen ${toString cfg.port};
            ssl_preread on;
            proxy_pass $sni_backend;
            proxy_protocol on; # all registered backends are expected to accept proxy protocol
            ${lib.optionalString metricsEnabled ''
              access_log syslog:server=unix:/dev/log,tag=nginx-stream metrics_json;
            ''}
          }
        '';
      };

      networking.firewall.allowedTCPPorts = [ cfg.port ];
    }

    (mkIf metricsEnabled {
      systemd.services.nginx-stream-collector = {
        description = "nginx stream log to textfile collector";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${streamCollector}/bin/nginx-stream-collector";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths = [
            config.roles.observability.agent.textfileDir
            "/var/lib/nginx-stream-collector"
          ];
          StateDirectory = "nginx-stream-collector";
        };
      };

      systemd.timers.nginx-stream-collector = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "45s";
          OnUnitActiveSec = "30s";
          AccuracySec = "1s";
          Unit = "nginx-stream-collector.service";
        };
      };
    })
  ]);
```

- [ ] **Step 2: Validate the bounded nginx map and jq transform against a fixture**

```bash
cat > /tmp/journal-line.json <<'EOF'
{"__CURSOR":"s=abc;i=1;u=xyz","MESSAGE":"{\"sni\":\"ghcr.io\",\"status\":502,\"sent\":517,\"recv\":5171,\"time\":\"0.031\",\"uct\":\"-\"}"}
{"__CURSOR":"s=abc;i=2;u=xyz","MESSAGE":"{\"sni\":\"vk.ru\",\"status\":200,\"sent\":94000,\"recv\":21000,\"time\":\"12.500\",\"uct\":\"0.004\"}"}
EOF
jq -r '.MESSAGE | fromjson | [ (.sni // "unknown"), (.status | tostring), (.sent | tostring), (.recv | tostring), (((.time | tonumber? // 0) * 1000) | round | tostring) ] | @tsv' /tmp/journal-line.json
```

Expected:
```
ghcr.io	502	517	5171	31
vk.ru	200	94000	21000	12500
```

- [ ] **Step 3: Format, evaluate, check**

```bash
nixfmt roles/network/sni-router.nix
nix eval path:.#nixosConfigurations.veles.config.services.nginx.streamConfig --raw | grep -A12 'map $ssl_preread_server_name $metrics_sni'
nix flake check 'path:.' --all-systems
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add roles/network/sni-router.nix
git commit -m "feat(sni-router): stream session metrics via journald textfile collector"
```

---

### Task 5: Machine wiring (tailscale enrollment, agents, port move)

**Files:**
- Modify: `machines/mokosh/default.nix`
- Modify: `machines/veles/default.nix`
- Modify: `machines/buyan/default.nix`
- Modify: `machines/nixpi/default.nix`
- Modify: `secrets/unlocked/spec.txt`

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: enrolled tailnet members with retrying initial autoconnect; agent role on mokosh/veles/buyan; xray metrics + stream metrics active on veles/buyan; `remoteAgents = [veles, buyan]` on mokosh.

- [ ] **Step 1: mokosh — tailscale + agent + remoteAgents**

In `machines/mokosh/default.nix`, extend the observability block and add tailscale next to it:

```nix
  roles.observability = {
    enable = true;
    agent.enable = true;
    baseDomain = domainNames.secondary;
    remoteAgents = [
      { host = "veles"; }
      { host = "buyan"; }
    ];
  };

  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = "/etc/nixos/secrets/tailscale-auth-key-mokosh";
    extraUpFlags = [ "--login-server=https://headscale.uspenskiy.tech" ];
    extraSetFlags = [ "--accept-dns=true" ];
  };

  # Mokosh enrolls through its own public Headscale endpoint. Avoid racing the
  # first auth-key submission against the local control plane and reverse proxy.
  systemd.services.tailscaled-autoconnect = {
    after = [
      "headscale.service"
      "nginx.service"
    ];
    wants = [
      "headscale.service"
      "nginx.service"
    ];
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "30s";
    };
  };
```

- [ ] **Step 2: veles — tailscale + agent + xray metrics + mtproxy port**

In `machines/veles/default.nix`:

```nix
  roles.observability.agent.enable = true;

  roles.xray.metrics.enable = true;

  roles.mtproxy = {
    enable = true;
    useMiddleProxy = false;
    tls.domain = "api.ok.ru";
    port = 9102; # moved off 9100: node_exporter owns 9100 on agents
    upstream = "127.0.0.1:1080";
    users = secrets.mtproxy.users;
  };

  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = "/etc/nixos/secrets/tailscale-auth-key-veles";
    extraUpFlags = [
      "--login-server=https://headscale.uspenskiy.tech"
      "--accept-dns=false"
    ];
    extraSetFlags = [ "--accept-dns=false" ];
  };

  systemd.services.tailscaled-autoconnect.serviceConfig = {
    Restart = "on-failure";
    RestartSec = "30s";
  };
```

First verify 9102 is unused on veles:

```bash
grep -rn "9102" machines/veles roles/ || echo "free"
```

- [ ] **Step 3: buyan — tailscale + agent + xray metrics**

In `machines/buyan/default.nix`:

```nix
  roles.observability.agent.enable = true;

  roles.xray.metrics.enable = true;

  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = "/etc/nixos/secrets/tailscale-auth-key-buyan";
    extraUpFlags = [
      "--login-server=https://headscale.uspenskiy.tech"
      "--accept-dns=false"
    ];
    extraSetFlags = [ "--accept-dns=false" ];
  };

  systemd.services.tailscaled-autoconnect.serviceConfig = {
    Restart = "on-failure";
    RestartSec = "30s";
  };
```

- [ ] **Step 4: nixpi — pin resolver against MagicDNS push**

In `machines/nixpi/default.nix`, extend the existing `services.tailscale` block:

```nix
  services.tailscale = {
    enable = true;
    openFirewall = true;
    disableUpstreamLogging = true;
    extraSetFlags = [ "--accept-dns=false" ];
  };
```

- [ ] **Step 5: Add the tracked secret installation manifest entries**

Append these non-secret declarations to `secrets/unlocked/spec.txt`:

```text
mokosh:tailscale-auth-key-mokosh:0400:root:root
veles:tailscale-auth-key-veles:0400:root:root
buyan:tailscale-auth-key-buyan:0400:root:root
```

Do not add the corresponding files under `secrets/unlocked/`; they remain gitignored key material created during Task 7's operator handoff.

- [ ] **Step 6: Format, spot-eval, check**

```bash
nixfmt machines/mokosh/default.nix machines/veles/default.nix machines/buyan/default.nix machines/nixpi/default.nix
nix eval path:.#nixosConfigurations.mokosh.config.services.victoriametrics.prometheusConfig.scrape_configs --json | jq '.[] | select(.job_name=="node")'
nix eval path:.#nixosConfigurations.mokosh.config.systemd.services.tailscaled-autoconnect.after --json
nix eval path:.#nixosConfigurations.veles.config.systemd.services.tailscaled-autoconnect.serviceConfig.Restart --raw
nix eval path:.#nixosConfigurations.veles.config.roles.xray.metrics.enable
nix eval path:.#nixosConfigurations.veles.config.services.prometheus.exporters.node.listenAddress
nix eval path:.#nixosConfigurations.mokosh.config.services.tailscale.extraSetFlags --json
nix eval path:.#nixosConfigurations.veles.config.services.tailscale.extraSetFlags --json
nix eval path:.#nixosConfigurations.veles.config.networking.firewall.interfaces --json
git ls-files --error-unmatch secrets/unlocked/spec.txt
nix flake check 'path:.' --all-systems
```

Expected: node job has three static_configs (mokosh loopback + `veles.ts:9100` + `buyan.ts:9100`, host labels `mokosh`/`veles`/`buyan`); autoconnect ordering contains `headscale.service` and `nginx.service`; restart policy is `on-failure`; `true`; `"0.0.0.0"`; DNS set flags are `["--accept-dns=true"]` on mokosh and `["--accept-dns=false"]` on veles; firewall `tailscale0` → `[9100]`; `spec.txt` is tracked; flake check PASS.

- [ ] **Step 7: Commit**

```bash
git add machines/mokosh/default.nix machines/veles/default.nix machines/buyan/default.nix machines/nixpi/default.nix secrets/unlocked/spec.txt
git commit -m "feat(machines): tailnet enrollment and metrics agents on mokosh, veles, buyan"
```

---

### Task 6: proxy-health dashboard

**Files:**
- Create: `roles/observability/dashboards/proxy-health.json`

**Interfaces:**
- Consumes: metric names produced by Tasks 2–4 (`node_netstat_*`, `tcp_states`, `nginx_stream_*`, `xray_*`) and the `host` label; Grafana provisioning already loads every JSON in `./dashboards` (see `roles/observability/grafana.nix`).
- Produces: dashboard uid `proxy-health`.

- [ ] **Step 1: Generate the dashboard JSON**

The existing `machines-overview.json` uses Grafana's `dashboard.grafana.app/v2` provisioning schema (envelope + `spec.elements` + `spec.layout` + `spec.variables`). Generate the new dashboard in the same schema by running this script from the worktree root:

```bash
python3 - <<'PYEOF'
import json

panels = [
    # (title, [(expr, legend)], unit, row)
    ("TCP data retransmissions",
     [("rate(node_netstat_Tcp_RetransSegs{host=~\"$host\"}[$__rate_interval])", "{{host}}")],
     "ops", "TCP / Kernel"),
    ("SYN/SYN-ACK retransmissions and timeouts",
     [("rate(node_netstat_TcpExt_TCPSynRetrans{host=~\"$host\"}[$__rate_interval])", "handshake retrans {{host}}"),
      ("rate(node_netstat_TcpExt_TCPTimeouts{host=~\"$host\"}[$__rate_interval])", "timeouts {{host}}")],
     "ops", "TCP / Kernel"),
    ("Half-open handshakes (SYN_RECV)",
     [("tcp_states{host=~\"$host\",state=\"syn_recv\"}", "{{host}}")],
     "short", "TCP / Kernel"),
    ("Listen drops",
     [("rate(node_netstat_TcpExt_ListenDrops{host=~\"$host\"}[$__rate_interval])", "{{host}}")],
     "ops", "TCP / Kernel"),
    ("UDP errors",
     [("rate(node_netstat_Udp_InErrors{host=~\"$host\"}[$__rate_interval])", "in {{host}}"),
      ("rate(node_netstat_Udp_RcvbufErrors{host=~\"$host\"}[$__rate_interval])", "rcvbuf {{host}}"),
      ("rate(node_netstat_Udp_SndbufErrors{host=~\"$host\"}[$__rate_interval])", "sndbuf {{host}}")],
     "ops", "TCP / Kernel"),
    ("Stream sessions by status",
     [("sum by (host, sni, status) (rate(nginx_stream_sessions_total{host=~\"$host\"}[$__rate_interval]))", "{{host}} {{sni}} {{status}}")],
     "ops", "nginx stream"),
    ("Stream bytes: sent vs received",
     [("sum by (host, sni) (rate(nginx_stream_sent_bytes_total{host=~\"$host\"}[$__rate_interval]))", "{{host}} {{sni}} sent"),
      ("sum by (host, sni) (rate(nginx_stream_received_bytes_total{host=~\"$host\"}[$__rate_interval]))", "{{host}} {{sni}} recv")],
     "Bps", "nginx stream"),
    ("Short status-200 sessions (≤1s)",
     [("sum by (host, sni) (rate(nginx_stream_session_duration_seconds_bucket{host=~\"$host\",status=\"200\",le=\"1\"}[$__rate_interval]))", "{{host}} {{sni}}")],
     "ops", "nginx stream"),
    ("Status-200 session duration p95",
     [("histogram_quantile(0.95, sum by (le, host, sni) (rate(nginx_stream_session_duration_seconds_bucket{host=~\"$host\",status=\"200\"}[$__rate_interval])))", "{{host}} {{sni}}")],
     "s", "nginx stream"),
    ("xray inbound traffic",
     [("sum by (host, inbound) (rate(xray_inbound_uplink_bytes_total{host=~\"$host\"}[$__rate_interval]))", "{{host}} {{inbound}} up"),
      ("sum by (host, inbound) (rate(xray_inbound_downlink_bytes_total{host=~\"$host\"}[$__rate_interval]))", "{{host}} {{inbound}} down")],
     "Bps", "xray"),
    ("xray outbound traffic",
     [("sum by (host, outbound) (rate(xray_outbound_uplink_bytes_total{host=~\"$host\"}[$__rate_interval]))", "{{host}} {{outbound}} up"),
      ("sum by (host, outbound) (rate(xray_outbound_downlink_bytes_total{host=~\"$host\"}[$__rate_interval]))", "{{host}} {{outbound}} down")],
     "Bps", "xray"),
    ("Observatory probe delay",
     [("xray_observatory_delay_milliseconds{host=~\"$host\"}", "{{host}} {{outbound}}")],
     "ms", "xray"),
    ("Observatory outbound alive",
     [("xray_observatory_alive{host=~\"$host\"}", "{{host}} {{outbound}}")],
     "short", "xray"),
]

rows = ["TCP / Kernel", "nginx stream", "xray"]
elements = {}
layout_items = {r: [] for r in rows}
row_y = {r: 0 for r in rows}
for i, (title, queries, unit, row) in enumerate(panels, start=1):
    name = f"panel-{i}"
    elements[name] = {
        "kind": "Panel",
        "spec": {
            "id": i,
            "title": title,
            "description": "",
            "links": [],
            "data": {
                "kind": "QueryGroup",
                "spec": {
                    "queries": [
                        {
                            "kind": "PanelQuery",
                            "spec": {
                                "query": {
                                    "kind": "DataQuery",
                                    "group": "prometheus",
                                    "version": "v0",
                                    "datasource": {"name": "victoriametrics"},
                                    "spec": {
                                        "editorMode": "code",
                                        "expr": expr,
                                        "legendFormat": legend,
                                        "range": True,
                                    },
                                },
                                "refId": chr(ord("A") + qi),
                                "hidden": False,
                            },
                        }
                        for qi, (expr, legend) in enumerate(queries)
                    ],
                    "transformations": [],
                    "queryOptions": {},
                },
            },
            "vizConfig": {
                "kind": "VizConfig",
                "group": "timeseries",
                "version": "13.0.7",
                "spec": {
                    "options": {
                        "legend": {
                            "calcs": [],
                            "displayMode": "list",
                            "placement": "bottom",
                            "showLegend": True,
                        },
                        "tooltip": {"hideZeros": False, "mode": "single", "sort": "none"},
                    },
                    "fieldConfig": {
                        "defaults": {"unit": unit},
                        "overrides": [],
                    },
                },
            },
        },
    }
    layout_items[row].append({
        "kind": "GridLayoutItem",
        "spec": {"x": 0, "y": row_y[row], "width": 12, "height": 8,
                 "element": {"kind": "ElementReference", "name": name}},
    })
    row_y[row] += 8

dashboard = {
    "apiVersion": "dashboard.grafana.app/v2",
    "kind": "Dashboard",
    "metadata": {"name": "proxy-health", "namespace": "default", "uid": "proxy-health"},
    "spec": {
        "title": "Proxy Health",
        "description": "Tailnet-scraped proxy host health: kernel TCP signals, nginx stream sessions, xray traffic and observatory",
        "tags": ["tailnet", "proxy"],
        "editable": False,
        "timeSettings": {"from": "now-6h", "to": "now"},
        "variables": [
            {
                "kind": "QueryVariable",
                "spec": {
                    "name": "host",
                    "current": {"text": "veles", "value": "veles"},
                    "label": "Host",
                    "hide": "dontHide",
                    "refresh": "onDashboardLoad",
                    "skipUrlSync": False,
                    "query": {
                        "kind": "DataQuery",
                        "group": "prometheus",
                        "version": "v0",
                        "datasource": {"name": "victoriametrics"},
                        "spec": {"__legacyStringValue": "label_values(up, host)"},
                    },
                    "regex": "",
                    "regexApplyTo": "value",
                    "sort": "disabled",
                    "options": [],
                    "multi": True,
                    "includeAll": True,
                    "allValue": ".*",
                    "allowCustomValue": True,
                },
            }
        ],
        "layout": {
            "kind": "RowsLayout",
            "spec": {
                "rows": [
                    {
                        "kind": "RowsLayoutRow",
                        "spec": {
                            "title": row,
                            "collapse": False,
                            "layout": {"kind": "GridLayout", "spec": {"items": layout_items[row]}},
                        },
                    }
                    for row in rows
                ]
            },
        },
        "elements": elements,
        "annotations": [],
        "links": [],
        "liveNow": False,
        "preload": False,
        "cursorSync": "Off",
    },
}

with open("roles/observability/dashboards/proxy-health.json", "w") as f:
    json.dump(dashboard, f, indent=2)
    f.write("\n")
PYEOF
```

- [ ] **Step 2: Validate the JSON parses and references only known metrics**

```bash
jq -e '.spec.title' roles/observability/dashboards/proxy-health.json
jq -e '.spec.annotations | type == "array"' roles/observability/dashboards/proxy-health.json
jq -e '[.. | objects | .expr? // empty | select(contains("host")) | contains("host=~")] | all' roles/observability/dashboards/proxy-health.json
grep -o 'xray_[a-z_]*\|nginx_stream_[a-z_]*\|tcp_states\|node_netstat_[A-Za-z_]*' roles/observability/dashboards/proxy-health.json | sort -u
```

Expected: `"Proxy Health"`; both schema/query assertions return `true`; metric list matches Tasks 2–4 outputs only.

- [ ] **Step 3: Flake check**

```bash
nix flake check 'path:.' --all-systems
```

Expected: PASS (dashboard dir is imported by grafana.nix provisioning path).

- [ ] **Step 4: Commit**

```bash
git add roles/observability/dashboards/proxy-health.json
git commit -m "feat(grafana): proxy-health dashboard for tailnet agents"
```

---

### Task 7: Final validation and operator runbook handoff

**Files:**
- No repo files changed (the tracked secret installation manifest was committed in Task 5; key material remains gitignored).

**Interfaces:**
- Produces: verification that the branch is complete; documented operator steps.

- [ ] **Step 1: Full check**

```bash
nixfmt .
git status --short   # stage and commit any reformatted files explicitly by path
nix flake check 'path:.' --all-systems
git log --oneline main..HEAD
```

Expected: flake check PASS. If commits were authorized, the commit list contains Tasks 1–6 plus any explicit nixfmt fixup; otherwise `git status --short` lists only the intended implementation files.

- [ ] **Step 2: Report operator runbook (no automation)**

Surface these steps to the operator verbatim — they are one-time manual actions that cannot be committed:

1. On mokosh, run `sudo headscale users list` and note the intended user's numeric ID. Create three distinct one-time keys by running `sudo headscale preauthkeys create --user <user-id> --expiration 24h --reusable=false --ephemeral=false` once for each new node, immediately recording which returned key is for mokosh, veles, or buyan.
2. Never run `make lock` with these ephemeral keys present: do not add them to `secrets/locked.tar.gpg` or any tracked artifact. On each host, run `make unlock`, securely place only its key at the gitignored `secrets/unlocked/tailscale-auth-key-<hostname>` path, run `make install-secrets`, and remove that gitignored transfer copy after successful enrollment.
3. Deploy in order: mokosh → veles → buyan. Complete initial enrollment before each key's explicit expiry.
4. If a node later loses its Tailscale state, create and install a fresh one-time key for that host before redeploying it.
5. Post-deploy validation (spec's Operational Runbook section): `tailscale status`, `getent hosts veles.ts` on mokosh, `tailscale netcheck`, public Headscale/DERP health, `curl http://veles.ts:9100/metrics` from mokosh, fresh `node_textfile_mtime_seconds` entries for all three collector files, collector systemd units healthy, public port scan shows 9100 is not open, and Grafana `proxy-health` renders. Expect `xray_` and `nginx_stream_` samples only after their corresponding proxy paths have handled traffic.

- [ ] **Step 3: Final commit if nixfmt changed anything**

```bash
git status --short
# if anything is listed:
git add <files> && git commit -m "style: nixfmt tailnet metrics branch"
```

---

## Self-Review Notes

- Spec coverage: MagicDNS (Task 1), agent split + node job + host labels (Task 2), xray expvar + observatory + policy counters (Task 3), bounded stream JSON labels + session/byte/duration histogram metrics (Task 4), native enrollment + tracked host-specific secret manifest + DNS posture per host + mtproxy port move (Task 5), dashboard (Task 6), runbook (Task 7).
- `scrapeJobType.host` defaults to `config.networking.hostName`, matching the spec's requirement that local jobs use the registering host's hostname.
- Task 4 weaves the bounded-label nginx `map`, `log_format`, and `access_log` directives into the existing `streamConfig` string via `optionalString metricsEnabled`; nginx rejects formats defined after the referencing `server{}` block.
