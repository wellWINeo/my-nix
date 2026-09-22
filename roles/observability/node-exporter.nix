{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  agent = config.roles.observability.agent;

  tcpStateCollector = pkgs.writeShellApplication {
    name = "tcp-state-collector";
    runtimeInputs = [
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
