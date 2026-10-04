#!/usr/bin/env bash
set -euo pipefail
flake="${1:?pass path:source-tree}"
veles=$(nix eval --json "$flake#nixosConfigurations.veles.config.roles.xray._configTemplate")
buyan=$(nix eval --json "$flake#nixosConfigurations.buyan.config.roles.xray._configTemplate")
printf '%s' "$veles" | jq -e '
  . as $cfg |
  ([.inbounds[] | select(.tag == "vless-xhttp-in") | .settings.clients[] | select(.reverse.tag? == "reverse-buyan-out")] | length == 1)
  and ([.inbounds[] | select(.tag != "vless-xhttp-in") | .settings.clients[]? | select(.reverse? != null)] | length == 0)
  and (.outbounds[0].tag == "direct-out")
  and (["vless-tcp-in", "vless-grpc-in", "vless-xhttp-in"] as $tags |
       all($tags[]; . as $tag | [$cfg.routing.rules[] | select((.inboundTag // []) | index($tag)) | .outboundTag] == ["direct-out"]))
' >/dev/null
printf '%s' "$buyan" | jq -e --argjson veles "$veles" '
  ([$veles.inbounds[] | select(.tag == "vless-xhttp-in") | .streamSettings.realitySettings.serverNames[0]]) as $velesSni |
  ([$veles.inbounds[] | select(.tag == "vless-xhttp-in") | .streamSettings.xhttpSettings.path]) as $velesPath |
  ([.outbounds[] | select(.tag == "reverse-veles-client") | select(.settings.vnext? == null and .settings.reverse.tag == "reverse-veles-in" and .streamSettings.network == "xhttp" and .streamSettings.realitySettings.fingerprint == "firefox")] | length == 1)
  and ([.outbounds[] | select(.tag == "reverse-veles-client") | .streamSettings.realitySettings.serverName] == $velesSni)
  and ([.outbounds[] | select(.tag == "reverse-veles-client") | .streamSettings.xhttpSettings.path] == $velesPath)
  and ([.outbounds[] | select(.tag == "reverse-public-out") | .settings.finalRules] == [[{"action":"allow","network":"tcp,udp","ip":["!geoip:private"]}]])
  and ([.routing.rules[] | select((.inboundTag // []) | index("reverse-veles-in")) | .outboundTag] == ["reverse-public-out"])
  and (.outbounds[0].tag == "direct-out")
' >/dev/null

# Cutover-mode checks: evaluate roles.xray.relay.useReverse = true as a
# temporary extendModules override on the template (tracked host configs stay
# in staging with useReverse unset/false).
cutover=$(nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'";
in (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.relay.useReverse = true; } ];
}).config.roles.xray._configTemplate
')
printf '%s' "$cutover" | jq -e '
  . as $cfg |
  ([.routing.balancers[] | select(.tag == "reverse-first-balancer" and .selector == ["reverse-buyan-out"] and .fallbackTag == "relay-grpc-out")] | length == 1)
  and ([.outbounds[] | select(.tag == "relay-grpc-out")] | length == 1)
  and ([.routing.balancers[] | select(.tag == "relay-balancer")] | length == 1)
  and (.observatory.subjectSelector == ["relay-", "reverse-buyan-out"])
  and (["socks-relay-in", "vless-tcp-fwd-in", "vless-grpcFwd-in", "vless-xhttp-fwd-in", "hy2-relay-in"] as $tags |
       all($tags[]; . as $tag | [$cfg.routing.rules[] | select((.inboundTag // []) | index($tag)) | .balancerTag] == ["reverse-first-balancer"]))
' >/dev/null

# Staging stays the default: the unmodified veles template keeps relay traffic
# on relay-balancer and must not gain a reverse-first balancer.
printf '%s' "$veles" | jq -e '
  ([.routing.balancers[] | select(.tag == "reverse-first-balancer")] | length == 0)
  and ([.routing.rules[] | select((.inboundTag // []) | index("socks-relay-in")) | .balancerTag] == ["relay-balancer"])
' >/dev/null

# Failure-mode checks: lazily filter the failed assertions down to their
# messages before forcing them (forcing the full assertions array trips a
# pre-existing filesystems.nix lazy-eval error on this nixpkgs), then require
# the expected message. lib is bound from the flake because it is not in
# --expr scope.
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in map (a: a.message) (lib.filter (a: !a.assertion) (f.nixosConfigurations.veles.extendModules {
  modules = [ {
    roles.xray.relay.useReverse = true;
    roles.xray.relay.target.vlessGrpc.enable = lib.mkForce false;
  } ];
}).config.assertions)
' | jq -e 'any(.[]; contains("useReverse"))' >/dev/null

nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in map (a: a.message) (lib.filter (a: !a.assertion) (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.server.vlessXhttp.enable = lib.mkForce false; } ];
}).config.assertions)
' | jq -e 'any(.[]; contains("reverse.portal"))' >/dev/null

# Dashboard queries must distinguish Veles probe health from reverse traffic
# and show both directions without treating an absent probe as a healthy link.
jq -e '
  .spec as $s |
  ($s.elements["panel-14"] | .spec.data.spec.queries[0].spec.query.spec.expr == "xray_observatory_alive{host=\"veles\",outbound=\"reverse-buyan-out\"}" and .spec.vizConfig.spec.fieldConfig.defaults.unit == "short")
  and ($s.elements["panel-15"] | [.spec.data.spec.queries[].spec.query.spec.expr] == [
    "sum by (host, outbound) (rate(xray_outbound_uplink_bytes_total{host=~\"$host\",outbound=~\"reverse-buyan-out|reverse-veles-client|reverse-public-out\"}[$__rate_interval]))",
    "sum by (host, outbound) (rate(xray_outbound_downlink_bytes_total{host=~\"$host\",outbound=~\"reverse-buyan-out|reverse-veles-client|reverse-public-out\"}[$__rate_interval]))"
  ] and .spec.vizConfig.spec.fieldConfig.defaults.unit == "Bps")
  and any($s.layout.spec.rows[]; .spec.title == "xray reverse" and ([.spec.layout.spec.items[].spec.element.name] | sort == ["panel-14", "panel-15"]))
' "${flake#path:}/roles/observability/dashboards/proxy-health.json" >/dev/null
