#!/usr/bin/env bash
# Eval-time topology tests for the xray role's integrated server/relay modes.
#
# Checks the generated roles.xray._configTemplate of the tracked hosts:
#   veles — relay mode, egress.via = "reverse" (Buyan-initiated reverse links)
#   buyan — server mode with reverseBridge (two bridge outbounds to Veles)
# plus the CDN origin wiring (SNI-router entry order, Nginx HTTPS origin vhost,
# HTTP-01 ACME, static probe page), forward-mode and failure-mode variations
# via extendModules, and the dashboard's generic reverse tag queries.
#
# Only dummy secrets are evaluated; user UUIDs are kept in shell/jq variables
# and never printed.
set -euo pipefail
flake="${1:?pass path:source-tree}"
veles=$(nix eval --json "$flake#nixosConfigurations.veles.config.roles.xray._configTemplate")
buyan=$(nix eval --json "$flake#nixosConfigurations.buyan.config.roles.xray._configTemplate")

# --- Veles relay topology: five generic inbounds, blackhole-first egress, reverse balancer ---
printf '%s' "$veles" | jq -e '
  . as $cfg |
  ([.inbounds[].tag] | sort == ["hy2-relay-in", "vless-cdn-xhttp-in", "vless-grpc-in", "vless-raw-in", "vless-xhttp-in"])
  and (.outbounds[0].tag == "blocked-out")
  and ([.outbounds[] | select(.tag == "direct-out" or (.tag | startswith("forward-")))] | length == 0)
  and ([.routing.balancers[] | select(.tag == "reverse-balancer" and .strategy.type == "leastPing" and .selector == ["reverse-raw-out", "reverse-xhttp-out"] and .fallbackTag == "blocked-out")] | length == 1)
  and (["vless-raw-in", "vless-grpc-in", "vless-xhttp-in", "hy2-relay-in", "vless-cdn-xhttp-in"] as $ingress |
    all($ingress[]; . as $tag |
      ([$cfg.routing.rules[] | select((.inboundTag // []) | index($tag)) | .balancerTag] == ["reverse-balancer"])
      # No matching rule may bypass the balancer with a static outboundTag.
      # (Plain `.outboundTag` on a rule without the key yields null, so the
      # projection must be guarded with has("outboundTag") to be satisfiable.)
      and ([$cfg.routing.rules[] | select(((.inboundTag // []) | index($tag)) and has("outboundTag")) | .outboundTag] == [])))
  and (all(["reverse-raw-out", "reverse-xhttp-out"][]; . as $tag | any($cfg.observatory.subjectSelector[]; . as $sel | $tag | startswith($sel))))
' >/dev/null

# --- Removed paths stay removed: no MTProxy service, no MTProxy SNI entry, no
# extra VLESS listener beyond the three loopback ingress inbounds. The relay
# SOCKS listener (socks-relay-in) absence is asserted above. ---
nix eval --impure --json --expr 'let f = builtins.getFlake "'"$flake"'"; in f.nixosConfigurations.veles.config.systemd.services ? "telemt"' |
  jq -e '. == false' >/dev/null
nix eval --json "$flake#nixosConfigurations.veles.config.roles.sni-router.entries" |
  jq -e 'all(.[]; .sni != "api.ok.ru" and .backend != "127.0.0.1:9102")' >/dev/null
printf '%s' "$veles" | jq -e 'all(.inbounds[] | select(.protocol == "vless"); .listen == "127.0.0.1")' >/dev/null

# --- Veles ingress details: preserved relay ports/SNIs, RAW Vision only, no relay SOCKS ---
printf '%s' "$veles" | jq -e '
  ([.outbounds[].tag] | sort == ["blocked-out"])
  and ([.outbounds[] | select(.tag == "blocked-out") | .protocol] == ["blackhole"])
  and ([.inbounds[] | select(.tag == "socks-relay-in")] | length == 0)
  and ([.inbounds[].tag | select(endswith("-fwd-in"))] | length == 0)
  and ([.inbounds[] | select(.tag == "vless-raw-in") | .listen, .port, .streamSettings.realitySettings.serverNames[0]] == ["127.0.0.1", 9010, "api.oneme.ru"])
  and ([.inbounds[] | select(.tag == "vless-grpc-in") | .port, .streamSettings.realitySettings.serverNames[0], .streamSettings.grpcSettings.serviceName] == [9011, "avatars.mds.yandex.net", "VlGrpc"])
  and ([.inbounds[] | select(.tag == "vless-xhttp-in") | .port, .streamSettings.realitySettings.serverNames[0], .streamSettings.xhttpSettings.path] == [9012, "onlymir.ru", "/vl-xhttp"])
  and ([.inbounds[] | select(.tag == "hy2-relay-in") | .port, .protocol] == [443, "hysteria"])
  and (all(.inbounds[] | select(.tag == "vless-raw-in") | .settings.clients[]; .flow? == "xtls-rprx-vision"))
  and (all(.inbounds[] | select(.tag == "vless-grpc-in" or .tag == "vless-xhttp-in") | .settings.clients[]; .flow? == null))
' >/dev/null

# --- Veles reverse-marked portal clients: exactly the buyan user on RAW/xHTTP only ---
reverseId=$(jq -er '[.singBoxUsers[] | select(.name == "buyan")] | if length == 1 then .[0].uuid else error("expected one buyan user") end' "${flake#path:}/secrets/secrets.dummy.json")
# The configured REALITY public key authenticating the bridge links against
# Veles's runtime-loaded private key (kept in a variable; never printed).
realityPub=$(jq -er '.xray.reality.publicKey' "${flake#path:}/secrets/secrets.dummy.json")

# Cross-host bridge parity: each bridge outbound must authenticate against the
# corresponding Veles portal inbound with the configured REALITY public key, a
# short ID authorized by that inbound, the same REALITY SNI and (xHTTP) the
# same path. Veles's JSON carries no public key (its private key is a runtime
# credential), so the key is compared to the configured value passed as --arg.
bridge_parity='
  . as $cfg
  | ($veles.inbounds[] | select(.tag == "vless-raw-in") | .streamSettings) as $rawSs
  | ($veles.inbounds[] | select(.tag == "vless-xhttp-in") | .streamSettings) as $xhttpSs
  | [$cfg.outbounds[] | select(.tag == "bridge-raw-out")] as $rawBridge
  | [$cfg.outbounds[] | select(.tag == "bridge-xhttp-out")] as $xhttpBridge
  | ($rawBridge | length == 1)
    and ($xhttpBridge | length == 1)
    and ($rawBridge[0].streamSettings.realitySettings.serverName == $rawSs.realitySettings.serverNames[0])
    and ($rawBridge[0].streamSettings.realitySettings.publicKey == $key)
    and (any($rawSs.realitySettings.shortIds[]; . == $rawBridge[0].streamSettings.realitySettings.shortId))
    and ($xhttpBridge[0].streamSettings.realitySettings.serverName == $xhttpSs.realitySettings.serverNames[0])
    and ($xhttpBridge[0].streamSettings.realitySettings.publicKey == $key)
    and (any($xhttpSs.realitySettings.shortIds[]; . == $xhttpBridge[0].streamSettings.realitySettings.shortId))
    and ($xhttpBridge[0].streamSettings.xhttpSettings.path == $xhttpSs.xhttpSettings.path)
'

check_bridge_parity() {
  # Usage: check_bridge_parity <buyan-config-json>
  printf '%s' "$1" | jq -e --argjson veles "$veles" --arg key "$realityPub" "$bridge_parity" >/dev/null
}
printf '%s' "$veles" | jq -e --arg id "$reverseId" '
  ([.inbounds[] | select(.tag == "vless-raw-in") | .settings.clients[] | select(.id == $id and .reverse.tag? == "reverse-raw-out" and .email == "buyan@xray")] | length == 1)
  and ([.inbounds[] | select(.tag == "vless-xhttp-in") | .settings.clients[] | select(.id == $id and .reverse.tag? == "reverse-xhttp-out" and .email == "buyan@xray")] | length == 1)
  and ([.inbounds[] | .settings.clients[]? | select(.reverse? != null)] | length == 2)
  and ([.inbounds[] | select(.tag == "vless-grpc-in") | .settings.clients[] | select(.id == $id)] | length == 0)
  and ([.inbounds[] | select(.tag == "hy2-relay-in") | .settings.clients[]? | select(.email == "buyan@hysteria")] | length == 0)
' >/dev/null

# --- Veles CDN xHTTP ingress: loopback VLESS-encrypted packet-up inbound, ordinary clients only,
# reverse-balanced, with the runtime decryption sentinel in the store template (never "none"). ---
printf '%s' "$veles" | jq -e --arg id "$reverseId" '
  . as $cfg |
  ([.inbounds[] | select(.tag == "vless-cdn-xhttp-in")] | length == 1)
  and ([$cfg.inbounds[] | select(.tag == "vless-cdn-xhttp-in") |
    .listen, .port, .protocol, .streamSettings.network,
    .streamSettings.security, .streamSettings.xhttpSettings.mode,
    .streamSettings.xhttpSettings.path,
    .streamSettings.xhttpSettings.xPaddingObfsMode,
    .streamSettings.xhttpSettings.xPaddingPlacement,
    .streamSettings.xhttpSettings.xPaddingHeader,
    .streamSettings.xhttpSettings.xPaddingMethod,
    .settings.decryption] ==
    ["127.0.0.1", 9013, "vless", "xhttp", "none", "packet-up", "/vl-cdn",
     true, "header", "X-Request-Id", "tokenish", "@VLESS_CDN_DECRYPTION@"])
  and ([.inbounds[] | select(.tag == "vless-cdn-xhttp-in") | .settings.clients[] | select(.id == $id or .reverse? != null)] | length == 0)
  and (([.inbounds[] | select(.tag == "vless-cdn-xhttp-in") | .settings.clients[].id] | sort)
    == ([.inbounds[] | select(.tag == "vless-grpc-in") | .settings.clients[].id] | sort))
  and ([.routing.rules[] | select((.inboundTag // []) | index("vless-cdn-xhttp-in")) | .balancerTag] == ["reverse-balancer"])
  and ([.outbounds[].tag] == ["blocked-out"])
' >/dev/null

# The relay user list contains the reverse user exactly once (count only; never printed).
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; cfg = f.nixosConfigurations.veles.config.roles.xray.relay;
in builtins.length (builtins.filter (u: u.uuid == cfg.egress.reverse.user.uuid) cfg.ingress.users)
' | jq -e '. == 1' >/dev/null

# --- Veles CDN origin: the SNI-router origin entry is appended AFTER the REALITY
# entries and must never become the effective fallback. While defaultBackend is
# null, sni-router.nix falls back to the FIRST entry, so that entry has to stay
# the previous REALITY backend (the gRPC one here) and the origin entry last. ---
nix eval --json "$flake#nixosConfigurations.veles.config.roles.sni-router.entries" |
  jq -e '
    . == [
      { sni: "avatars.mds.yandex.net", backend: "127.0.0.1:9011", proxyProtocol: true },
      { sni: "api.oneme.ru", backend: "127.0.0.1:9010", proxyProtocol: true },
      { sni: "onlymir.ru", backend: "127.0.0.1:9012", proxyProtocol: true },
      { sni: "sunny-bee-on-the-flower.net.by", backend: "127.0.0.1:9443", proxyProtocol: true }
    ]
  ' >/dev/null
nix eval --json "$flake#nixosConfigurations.veles.config.roles.sni-router.defaultBackend" |
  jq -e '. == null' >/dev/null

# --- Veles CDN origin vhost: HTTP/80 (HTTP-01) plus a loopback HTTPS 9443
# listener consuming the stream router's PROXY protocol; the origin serves a
# static no-store page, a generic no-store 404, and proxies ONLY the exact
# /vl-cdn path and its session subpaths (no /vl-cdn-other prefix match) to the
# loopback XHTTP inbound without caching/buffering, intercepting expected Xray
# 4xx status codes as the same site-style 404. ---
originVhost=$(nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'";
  v = f.nixosConfigurations.veles.config.services.nginx.virtualHosts."sunny-bee-on-the-flower.net.by";
# Project only the asserted fields: the raw vhost option value leaves
# sslCertificate undefined by design (enableACME fills cert paths at render
# time), so serializing the whole vhost would fail spuriously.
in {
  enableACME = v.enableACME;
  addSSL = v.addSSL;
  listen = v.listen;
  locations = v.locations;
}')
printf '%s' "$originVhost" | jq -e '
  . as $vhost |
  ($vhost.enableACME == true)
  # NixOS emits ssl_certificate only when addSSL/onlySSL/forceSSL enables SSL;
  # an explicit ssl=true listen alone does not activate its cert directives.
  and ($vhost.addSSL == true)
  and (($vhost.listen | length) == 2)
  and (([$vhost.listen[] | { addr, port, ssl, proxyProtocol }]) == [
        { addr: "0.0.0.0", port: 80, ssl: false, proxyProtocol: false },
        { addr: "127.0.0.1", port: 9443, ssl: true, proxyProtocol: true }
      ])
  and (($vhost.locations | keys | sort) == [
        "/", "= /", "= /vl-cdn", "@probe_404", "^~ /vl-cdn/"
      ])
  and (all(["= /", "/", "@probe_404", "= /vl-cdn", "^~ /vl-cdn/"][];
        $vhost.locations[.].extraConfig | contains("no-store")))
  and ($vhost.locations["= /"].extraConfig | contains("return 200"))
  and (($vhost.locations["/"].extraConfig, $vhost.locations["@probe_404"].extraConfig) | all(.; contains("return 404")))
  and (([$vhost.locations["= /vl-cdn"], $vhost.locations["^~ /vl-cdn/"]] | all(
        .proxyPass == "http://127.0.0.1:9013"
        and (.extraConfig | contains("proxy_http_version 1.1")
             and contains("proxy_set_header Host $host")
             and contains("proxy_buffering off")
             and contains("proxy_request_buffering off")
             and contains("proxy_cache off")
             and contains("proxy_intercept_errors on")
             and contains("error_page 400 401 403 404 = @probe_404")))))
' >/dev/null

# HTTP-01 issuance (no DNS-01): NixOS's vhost enableACME must reload nginx on
# renewal and must not carry a dnsProvider.
nix eval --impure --json --expr 'let f = builtins.getFlake "'"$flake"'"; in f.nixosConfigurations.veles.config.security.acme.certs."sunny-bee-on-the-flower.net.by"' |
  jq -e '(.reloadServices | index("nginx.service") != null) and (.dnsProvider == null)' >/dev/null

# The common 443 stays a STREAM listener: no Nginx HTTP vhost may bind public
# 443 (the origin HTTPS lives on loopback 9443 behind the stream router).
nix eval --impure --json --expr 'let f = builtins.getFlake "'"$flake"'"; in builtins.mapAttrs (_: v: v.listen) f.nixosConfigurations.veles.config.services.nginx.virtualHosts' |
  jq -e '([.[][]] | length > 0) and ([.[][]] | all(.port != 443))' >/dev/null

# --- Buyan server topology: explicit direct-out for public inbounds, restricted reverse egress ---
printf '%s' "$buyan" | jq -e --argjson veles "$veles" '
  . as $cfg |
  ([.inbounds[] | select(.protocol == "vless") | .tag] | sort == ["vless-grpc-in", "vless-raw-in", "vless-xhttp-in"])
  and (.outbounds | map(.tag) == ["blocked-out", "direct-out", "bridge-raw-out", "bridge-xhttp-out", "reverse-public-out"])
  and ([.outbounds[] | select(.tag == "blocked-out") | .protocol] == ["blackhole"])
  and ([.outbounds[] | select(.tag == "direct-out") | .protocol] == ["freedom"])
  and ([.outbounds[] | select(.tag == "bridge-raw-out")] | length == 1)
  and ([.outbounds[] | select(.tag == "bridge-xhttp-out")] | length == 1)
  and ([.outbounds[] | select(.tag == "bridge-raw-out") |
        (.settings.vnext? == null)
        and .settings.reverse.tag == "reverse-raw-in"
        and .settings.flow? == "xtls-rprx-vision"
        and .streamSettings.network == "tcp"
        and .streamSettings.realitySettings.fingerprint == "firefox"] | all)
  and ([.outbounds[] | select(.tag == "bridge-xhttp-out") |
        (.settings.vnext? == null)
        and .settings.reverse.tag == "reverse-xhttp-in"
        and .settings.flow? == null
        and .streamSettings.network == "xhttp"
        and .streamSettings.realitySettings.fingerprint == "firefox"] | all)
  and ([.outbounds[] | select(.tag == "reverse-public-out") | .settings.finalRules] == [[{"action":"allow","network":"tcp,udp","ip":["!geoip:private"]}]])
  and (["vless-raw-in", "vless-grpc-in", "vless-xhttp-in"] as $public |
       all($public[]; . as $tag | [($cfg.routing.rules[] | select((.inboundTag // []) | index($tag)) | .outboundTag)] == ["direct-out"]))
  and ([.routing.rules[] | select((.inboundTag // []) == ["reverse-raw-in"])] | length == 1)
  and ([.routing.rules[] | select((.inboundTag // []) == ["reverse-xhttp-in"])] | length == 1)
  and ([.routing.rules[] | select((.inboundTag // []) | index("reverse-raw-in")) | .outboundTag] == ["reverse-public-out"])
  and ([.routing.rules[] | select((.inboundTag // []) | index("reverse-xhttp-in")) | .outboundTag] == ["reverse-public-out"])
' >/dev/null

# Both bridge outbounds authenticate as the buyan user.
printf '%s' "$buyan" | jq -e --arg id "$reverseId" '
  ([.outbounds[] | select(.tag == "bridge-raw-out" or .tag == "bridge-xhttp-out") | .settings.id] == [$id, $id])
' >/dev/null

# Positive cross-host parity: SNI/path/key/shortId match Veles's portal inbounds.
check_bridge_parity "$buyan"

# Negative probes: an intentionally mismatched bridge config (SNI, xHTTP path,
# REALITY public key or short ID) must be rejected by the cross-host check
# above; the module system alone cannot see the other host. Each variant must
# still evaluate, so only the parity predicate may reject it.
bridge_mismatch_must_fail() {
  # Usage: bridge_mismatch_must_fail <nix-attrs> <label>
  local out
  if ! out=$(nix eval --impure --json --expr '
let
  f = builtins.getFlake "'"$flake"'";
  lib = f.nixosConfigurations.buyan.lib;
in (f.nixosConfigurations.buyan.extendModules {
  modules = [ { '"$1"' } ];
}).config.roles.xray._configTemplate
'); then
    echo "bridge mismatch variant failed to evaluate: $2" >&2
    exit 1
  fi
  if check_bridge_parity "$out"; then
    echo "mismatched bridge config escaped the cross-host check: $2" >&2
    exit 1
  fi
}
bridge_mismatch_must_fail 'roles.xray.server.reverseBridge.vless.raw.serverName = lib.mkForce "mismatched.invalid";' "raw SNI"
bridge_mismatch_must_fail 'roles.xray.server.reverseBridge.vless.xhttp.path = lib.mkForce "/mismatched-path";' "xHTTP path"
bridge_mismatch_must_fail 'roles.xray.server.reverseBridge.reality.publicKey = lib.mkForce "mismatched-bridge-public-key";' "REALITY public key"
bridge_mismatch_must_fail 'roles.xray.server.reverseBridge.reality.shortId = lib.mkForce "ff";' "REALITY short ID"

# --- Systemd runtime: no secret-file reverse credential; relay hysteria credentials only on
# Veles; the jq dispatch still distinguishes hy2-relay-in from the server hy2-in tag. ---
for host in veles buyan; do
  nix eval --json "$flake#nixosConfigurations.$host.config.systemd.services.xray.serviceConfig.LoadCredential" |
    jq -e 'all(.[]; startswith("reverse-uuid:") | not)' >/dev/null

  # mktemp creates an extensionless config; both CLI invocations must declare JSON.
  script=$(nix eval --raw "$flake#nixosConfigurations.$host.config.systemd.services.xray.script")
  grep -Fq 'xray run -test -format json -config "$configFile"' <<< "$script"
  grep -Fq 'exec xray run -format json -config "$configFile"' <<< "$script"
done
nix eval --json "$flake#nixosConfigurations.veles.config.systemd.services.xray.serviceConfig.LoadCredential" |
  jq -e 'any(.[]; startswith("hysteria-relay-cert:")) and any(.[]; startswith("hysteria-relay-key:"))' >/dev/null
# CDN VLESS decryption is a veles-only runtime credential, loaded from the
# installed secret file path (never embedded in the store template). Its
# non-secret installer mapping must name the same file.
grep -Fxq 'veles:vlessenc-decryption-key:0400:root:root' secrets/unlocked/spec.txt
nix eval --json "$flake#nixosConfigurations.veles.config.systemd.services.xray.serviceConfig.LoadCredential" |
  jq -e 'any(.[]; . == "cdn-decryption:/etc/nixos/secrets/vlessenc-decryption-key")' >/dev/null
nix eval --json "$flake#nixosConfigurations.buyan.config.systemd.services.xray.serviceConfig.LoadCredential" |
  jq -e 'all(.[]; startswith("cdn-decryption:") | not)' >/dev/null
nix eval --json "$flake#nixosConfigurations.buyan.config.systemd.services.xray.serviceConfig.LoadCredential" |
  jq -e 'all(.[]; startswith("hysteria-relay-") | not)' >/dev/null
nix eval --raw "$flake#nixosConfigurations.veles.config.systemd.services.xray.script" | grep -Fq 'hy2-relay-in'
# The CDN decryption value is read as a file (--rawfile), never passed as an
# --arg value that would put it on the jq command line.
veles_script=$(nix eval --raw "$flake#nixosConfigurations.veles.config.systemd.services.xray.script")
grep -Fq -- '--rawfile decryption' <<< "$veles_script"
if grep -Fq -- '--arg decryption' <<< "$veles_script"; then
  echo "veles xray script must not pass the decryption value as --arg" >&2
  exit 1
fi

# --- CDN decryption startup guard: the rendered script must refuse to start on
# a missing, blank, whitespace-only or literal-'none' credential file (a bare
# 'none' would silently disable the inner VLESS encryption) and must still
# accept an ordinary non-key value. Verified against the exact rendered guard
# with controlled non-key sentinel files only, and the failure output must be
# exactly the static message so no value can leak into logs. ---
cdn_guard="$(awk '/^[[:space:]]*cdnDecryptionGuard\(\) \{$/{f=1} f{print} f&&/^[[:space:]]*\}$/{exit}' <<< "$veles_script")"
if [ -z "$cdn_guard" ]; then
  echo "rendered xray script lacks the cdnDecryptionGuard function" >&2
  exit 1
fi
guarddir="$(mktemp -d)"
run_cdn_guard() {
  CREDENTIALS_DIRECTORY="$guarddir" bash -c "$cdn_guard
cdnDecryptionGuard" >/dev/null 2>&1
}
run_cdn_guard_err() {
  CREDENTIALS_DIRECTORY="$guarddir" bash -c "$cdn_guard
cdnDecryptionGuard" 2>&1 >/dev/null
}
cdn_guard_reject() {
  # Usage: cdn_guard_reject <label>
  if run_cdn_guard; then
    echo "CDN decryption guard accepted $1" >&2
    rm -rf "$guarddir"
    exit 1
  fi
}
printf 'none\n' > "$guarddir/cdn-decryption"; cdn_guard_reject "the literal 'none' sentinel"
printf ' none \n' > "$guarddir/cdn-decryption"; cdn_guard_reject "'none' with surrounding whitespace"
: > "$guarddir/cdn-decryption"; cdn_guard_reject "a blank credential file"
printf ' \n\t\n' > "$guarddir/cdn-decryption"; cdn_guard_reject "a whitespace-only credential file"
rm -f "$guarddir/cdn-decryption"; cdn_guard_reject "a missing credential file"
# An ordinary dummy non-key value must still pass the guard.
printf 'dummy-non-key-decryption-value\n' > "$guarddir/cdn-decryption"
if ! run_cdn_guard; then
  echo "CDN decryption guard rejected an ordinary non-key value" >&2
  rm -rf "$guarddir"
  exit 1
fi
# Rejection output must be exactly the static message (nothing else printed).
printf 'none\n' > "$guarddir/cdn-decryption"
cdn_guard_err="$(run_cdn_guard_err)" || true
if [ "$cdn_guard_err" != "CDN VLESS decryption credential missing, blank, whitespace-only or the invalid 'none' sentinel" ]; then
  echo "CDN decryption guard failure output is not the single static message" >&2
  rm -rf "$guarddir"
  exit 1
fi
rm -rf "$guarddir"
# The server-side hysteria credential path is the jq else-branch, so the
# server tag itself does not appear in the script; the hy2-relay-in dispatch
# above plus the per-host LoadCredential lists prove the distinction.

# --- Metrics JSON attached by the coordinator on both relay and server hosts ---
printf '%s' "$veles" | jq -e '.metrics.listen != null and .policy.system.statsOutboundUplink == true' >/dev/null
printf '%s' "$buyan" | jq -e '.metrics.listen != null and .policy.system.statsOutboundUplink == true' >/dev/null

# --- Forward-mode variation (manual rollback): configured primary/backup candidates behind a
# leastPing balancer, still no Veles direct-out, and the reverse portal clients stay advertised. ---
forward=$(nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.relay.egress.via = lib.mkForce "forward"; } ];
}).config.roles.xray._configTemplate
')
printf '%s' "$forward" | jq -e '
  . as $cfg |
  ([.outbounds[].tag] | sort == [
    "blocked-out",
    "forward-grpc-backup-out", "forward-grpc-out",
    "forward-raw-backup-out", "forward-raw-out",
    "forward-xhttp-backup-out", "forward-xhttp-out"
  ])
  and ([.outbounds[] | select(.tag == "direct-out")] | length == 0)
  and ([.routing.balancers[] | select(.tag == "forward-balancer" and .strategy.type == "leastPing" and .fallbackTag == "blocked-out" and (.selector | sort == [
        "forward-grpc-backup-out", "forward-grpc-out",
        "forward-raw-backup-out", "forward-raw-out",
        "forward-xhttp-backup-out", "forward-xhttp-out"
      ]))] | length == 1)
  and ([.routing.balancers[] | select(.tag == "reverse-balancer")] | length == 0)
  and ([.inbounds[] | select(.tag == "vless-cdn-xhttp-in")] | length == 1)
  and (["vless-raw-in", "vless-grpc-in", "vless-xhttp-in", "hy2-relay-in", "vless-cdn-xhttp-in"] as $ingress |
       all($ingress[]; . as $tag | [$cfg.routing.rules[] | select((.inboundTag // []) | index($tag)) | .balancerTag] == ["forward-balancer"]))
  and (.observatory.subjectSelector == ["forward-"])
  and (all(.outbounds[] | select(.tag | startswith("forward-raw"));
        .settings.vnext[0].users[0].flow? == "xtls-rprx-vision"
        and .streamSettings.realitySettings.fingerprint == "randomized"
        and (if .tag | endswith("backup-out") then .settings.vnext[0].port == 2053 else .settings.vnext[0].port == 443 end)))
' >/dev/null
printf '%s' "$forward" | jq -e --arg id "$reverseId" '
  ([.inbounds[] | select(.tag == "vless-raw-in") | .settings.clients[] | select(.id == $id and .reverse.tag? == "reverse-raw-out")] | length == 1)
  and ([.inbounds[] | select(.tag == "vless-xhttp-in") | .settings.clients[] | select(.id == $id and .reverse.tag? == "reverse-xhttp-out")] | length == 1)
' >/dev/null

# --- Disabled-CDN variation: forcing cdnXhttp off restores the original four-inbound
# topology and drops the cdn-decryption credential (no inert credential, no inbound);
# the origin vhost and origin SNI entry disappear while the previous three REALITY
# entries stay. ---
disabledCdn=$(nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.relay.ingress.vless.cdnXhttp.enable = lib.mkForce false; } ];
}).config.roles.xray._configTemplate
')
printf '%s' "$disabledCdn" | jq -e '
  ([.inbounds[] | select(.tag == "vless-cdn-xhttp-in")] | length == 0)
  and ([.inbounds[].tag] | sort == ["hy2-relay-in", "vless-grpc-in", "vless-raw-in", "vless-xhttp-in"])
  and ([.routing.rules[] | select((.inboundTag // []) | index("vless-cdn-xhttp-in"))] | length == 0)
' >/dev/null
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.relay.ingress.vless.cdnXhttp.enable = lib.mkForce false; } ];
}).config.systemd.services.xray.serviceConfig.LoadCredential
' | jq -e 'all(.[]; startswith("cdn-decryption:") | not)' >/dev/null
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in builtins.attrNames (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.relay.ingress.vless.cdnXhttp.enable = lib.mkForce false; } ];
}).config.services.nginx.virtualHosts
' | jq -e 'index("sunny-bee-on-the-flower.net.by") == null' >/dev/null
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.relay.ingress.vless.cdnXhttp.enable = lib.mkForce false; } ];
}).config.roles.sni-router.entries
' | jq -e '(length == 3) and all(.[]; .sni != "sunny-bee-on-the-flower.net.by")' >/dev/null

# --- Failure-mode checks: lazily filter the failed assertions down to their
# messages before forcing them (forcing the full assertions array trips a
# pre-existing filesystems.nix lazy-eval error on this nixpkgs), then require
# the expected message. lib is bound from the flake because it is not in
# --expr scope. --argjson-free: the failed-eval output itself stays silent. ---

# Reverse mode requires a reverse user.
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in map (a: a.message) (lib.filter (a: !a.assertion) (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.relay.egress.reverse.user = lib.mkForce null; } ];
}).config.assertions)
' | jq -e 'any(.[]; contains("requires roles.xray.relay.egress.reverse.user"))' >/dev/null

# The reverse user's UUID must not be duplicated in the ordinary client lists.
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in map (a: a.message) (lib.filter (a: !a.assertion) (f.nixosConfigurations.veles.extendModules {
  modules = [ {
    roles.xray.relay.ingress.users = lib.mkForce (
      f.nixosConfigurations.veles.config.roles.xray.relay.ingress.users
      ++ [ f.nixosConfigurations.veles.config.roles.xray.relay.egress.reverse.user ]);
  } ];
}).config.assertions)
' | jq -e 'any(.[]; contains("must appear exactly once"))' >/dev/null

# Enabled ingress transports require a nonempty SNI.
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in map (a: a.message) (lib.filter (a: !a.assertion) (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.relay.ingress.vless.raw.sni = lib.mkForce ""; } ];
}).config.assertions)
' | jq -e 'any(.[]; contains(".sni must be set"))' >/dev/null

# Only one xray mode may run on a host.
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in map (a: a.message) (lib.filter (a: !a.assertion) (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.server.enable = true; } ];
}).config.assertions)
' | jq -e 'any(.[]; contains("only one"))' >/dev/null

# The Hysteria2 forward target must not combine insecure = true with a certificate pin.
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in map (a: a.message) (lib.filter (a: !a.assertion) (f.nixosConfigurations.veles.extendModules {
  modules = [ {
    roles.xray.relay.egress.forward.hysteria2.enable = lib.mkForce true;
    roles.xray.relay.egress.forward.hysteria2.certificateFingerprint = lib.mkForce "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
  } ];
}).config.assertions)
' | jq -e 'any(.[]; contains("certificateFingerprint"))' >/dev/null

# An enabled CDN ingress requires originDomain (and decryptionFile).
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in map (a: a.message) (lib.filter (a: !a.assertion) (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.relay.ingress.vless.cdnXhttp.originDomain = lib.mkForce ""; } ];
}).config.assertions)
' | jq -e 'any(.[]; contains("cdnXhttp requires originDomain"))' >/dev/null

# The CDN path must look like a URL path segment prefix.
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in map (a: a.message) (lib.filter (a: !a.assertion) (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.relay.ingress.vless.cdnXhttp.path = lib.mkForce "vl-cdn"; } ];
}).config.assertions)
' | jq -e 'any(.[]; contains("cdnXhttp.path"))' >/dev/null

# The CDN origin must not collide with an enabled REALITY ingress SNI.
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.nixosConfigurations.veles.lib;
in map (a: a.message) (lib.filter (a: !a.assertion) (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.relay.ingress.vless.cdnXhttp.originDomain = lib.mkForce "onlymir.ru"; } ];
}).config.assertions)
' | jq -e 'any(.[]; contains("must differ from every enabled REALITY ingress SNI"))' >/dev/null

# --- NixPi client mode (standalone checks; independent of Veles/Buyan migration) ---
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Sanitized projection: local ingress tags plus the three VLESS transports on
# both the 443 and 2053 candidates, leastPing-balanced with the preserved
# randomized fingerprint. The client stays forward-only: no reverse or
# blocked outbound may leak onto NixPi.
nixpi=$(nix eval --json "$flake#nixosConfigurations.nixpi.config.services.xray.settings")
printf '%s' "$nixpi" | jq -e '
  . as $cfg |
  ([.inbounds[].tag] | sort == ["http-in", "socks-in", "tunnel-0-in"])
  and ([.outbounds[].tag] | sort == [
        "direct-out",
        "vless-grpc-backup-out", "vless-grpc-out",
        "vless-tcp-backup-out", "vless-tcp-out",
        "vless-xhttp-backup-out", "vless-xhttp-out"
      ])
  and ([.routing.balancers[] | select(
        .tag == "proxy-balancer" and
        .strategy.type == "leastPing" and
        (.selector | sort == [
          "vless-grpc-backup-out", "vless-grpc-out",
          "vless-tcp-backup-out", "vless-tcp-out",
          "vless-xhttp-backup-out", "vless-xhttp-out"
        ])
      )] | length == 1)
  and (.observatory.subjectSelector == ["vless-"] and .observatory.probeInterval == "60s")
  and (all(.outbounds[];
        (.settings.reverse? == null) and
        (.tag | startswith("reverse-") | not) and
        (.tag != "blocked-out")))
  and (all(.outbounds[] | select(.tag | startswith("vless-"));
        (.settings.vnext[0].port) as $port |
        ((.settings.vnext[0].users[0].flow? == "xtls-rprx-vision") == (.tag | contains("tcp"))) and
        (.streamSettings.realitySettings.fingerprint == "randomized") and
        (if .tag | endswith("backup-out") then $port == 2053 else $port == 443 end)))
  and ([.outbounds[] | select(.tag == "vless-tcp-out") | .streamSettings.realitySettings.serverName] == ["api.oneme.ru"])
  and ([.outbounds[] | select(.tag == "vless-grpc-out") | .streamSettings.realitySettings.serverName, .streamSettings.grpcSettings.serviceName] == ["avatars.mds.yandex.net", "VlGrpc"])
  and ([.outbounds[] | select(.tag == "vless-xhttp-out") | .streamSettings.realitySettings.serverName, .streamSettings.xhttpSettings.path] == ["onlymir.ru", "/vl-xhttp"])
  and ([.inbounds[] | select(.tag == "tunnel-0-in") | .listen, .port, .settings.rewriteAddress, .settings.rewritePort] == ["127.0.0.1", 5053, "1.1.1.1", 853])
' >/dev/null

# The proxy listen ports stay firewall-opened (TCP SOCKS+HTTP, UDP SOCKS).
nix eval --json "$flake#nixosConfigurations.nixpi.config.networking.firewall.allowedTCPPorts" | jq -e '. as $ports | all([1081, 3128][]; $ports | index(.) != null)' >/dev/null
nix eval --json "$flake#nixosConfigurations.nixpi.config.networking.firewall.allowedUDPPorts" | jq -e '. as $ports | all([1081][]; $ports | index(.) != null)' >/dev/null

# Boundary validation: a malformed tunnel endpoint must fail evaluation with
# the endpoint-parser message (extendModules probe; tracked config untouched).
if nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'";
in (f.nixosConfigurations.nixpi.extendModules {
  modules = [ {
    roles.xray.client.ingress.tunnels = [ {
      listen = "127.0.0.1:not-a-port";
      target = "1.1.1.1:853";
    } ];
  } ];
}).config.services.xray.settings
' >/dev/null 2>"$tmp/nixpi-malformed.err"; then
  echo "nixpi accepted a malformed tunnel endpoint" >&2
  exit 1
fi
grep -q "must be ADDRESS:PORT" "$tmp/nixpi-malformed.err"

# --- Dashboard queries must distinguish Veles probe health from reverse traffic
# and show both directions without treating an absent probe as a healthy link. ---
jq -e '
  .spec as $s |
  ($s.elements["panel-14"] | .spec.data.spec.queries[0].spec.query.spec.expr == "xray_observatory_alive{host=\"veles\",outbound=~\"reverse-raw-out|reverse-xhttp-out\"}" and .spec.vizConfig.spec.fieldConfig.defaults.unit == "short")
  and ($s.elements["panel-15"] | [.spec.data.spec.queries[].spec.query.spec.expr] == [
    "sum by (host, outbound) (rate(xray_outbound_uplink_bytes_total{host=~\"$host\",outbound=~\"reverse-raw-out|reverse-xhttp-out|bridge-raw-out|bridge-xhttp-out|reverse-public-out\"}[$__rate_interval]))",
    "sum by (host, outbound) (rate(xray_outbound_downlink_bytes_total{host=~\"$host\",outbound=~\"reverse-raw-out|reverse-xhttp-out|bridge-raw-out|bridge-xhttp-out|reverse-public-out\"}[$__rate_interval]))"
  ] and .spec.vizConfig.spec.fieldConfig.defaults.unit == "Bps")
  and any($s.layout.spec.rows[]; .spec.title == "xray reverse" and ([.spec.layout.spec.items[].spec.element.name] | sort == ["panel-14", "panel-15"]))
' "${flake#path:}/roles/observability/dashboards/proxy-health.json" >/dev/null
