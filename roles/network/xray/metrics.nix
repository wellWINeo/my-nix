{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray.metrics;

  isValidRange =
    value: upperBound:
    let
      parsed = builtins.tryEval (toInt value);
    in
    parsed.success && parsed.value >= 0 && parsed.value <= upperBound;

  isLoopbackListen =
    let
      ipv4 = builtins.match "^127\\.([0-9]+)\\.([0-9]+)\\.([0-9]+):([0-9]+)$" cfg.listen;
      ipv6 = builtins.match "^[[]::1[]]:([0-9]+)$" cfg.listen;
    in
    (
      ipv4 != null
      && all (octet: isValidRange octet 255) (take 3 ipv4)
      && isValidRange (elemAt ipv4 3) 65535
    )
    || (ipv6 != null && isValidRange (head ipv6) 65535);

  collector = pkgs.writeShellApplication {
    name = "xray-metrics-collector";
    runtimeInputs = [
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
        assertion = isLoopbackListen;
        message = "roles.xray.metrics.listen must be a loopback address (127.0.0.0/8 or [::1]) with a numeric port";
      }
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
