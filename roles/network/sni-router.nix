# roles/network/sni-router.nix
#
# Shared SNI-based TLS routing via nginx stream.
# Other modules register entries via roles.sni-router.entries.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.sni-router;

  defaultBackend =
    if cfg.defaultBackend != null then
      cfg.defaultBackend
    else if cfg.entries != [ ] then
      (builtins.head cfg.entries).backend
    else
      "127.0.0.1:9000";

  metricsEnabled = cfg.enable && config.roles.observability.agent.enable;

  streamCollector = pkgs.writeShellApplication {
    name = "nginx-stream-collector";
    runtimeInputs = [
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
          stale_cursor="$cursor"
          cursor_line="$(journalctl --no-pager -n 1 --show-cursor | tail -n 1)"
          if [[ "$cursor_line" == "-- cursor: "* ]]; then
            cursor="''${cursor_line#-- cursor: }"
          else
            # An empty journal has no current cursor; retry the stale cursor
            # next run instead of replaying the retained journal entries.
            cursor="$stale_cursor"
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
in
{
  options.roles.sni-router = {
    enable = mkEnableOption "SNI-based TLS routing via nginx stream";

    port = mkOption {
      type = types.port;
      default = 443;
      description = "External port to listen on";
    };

    entries = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            sni = mkOption {
              type = types.str;
              description = "SNI hostname to match";
            };
            backend = mkOption {
              type = types.str;
              description = "Backend address (e.g. 127.0.0.1:9000)";
            };
            proxyProtocol = mkOption {
              type = types.bool;
              default = true;
              description = "Whether to emit proxy_protocol to this backend";
            };
          };
        }
      );
      default = [ ];
      description = "List of SNI → backend mappings";
    };

    defaultBackend = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Fallback backend; defaults to first entry if null";
    };
  };

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
            ${lib.concatMapStrings (e: "    ${e.sni}  ${e.sni};\n") cfg.entries}    default  unknown;
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
}
