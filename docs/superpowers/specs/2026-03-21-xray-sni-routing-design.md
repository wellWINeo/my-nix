# Xray SNI-Based Routing Design

## Problem

The current xray server architecture uses a single VLESS+TCP+Vision+Reality inbound on port 443 with fallbacks to route gRPC and xHTTP traffic to internal sub-inbounds. This doesn't work because:

1. xray's fallback `path` matching reads HTTP paths from the first packet as text (HTTP/1.1 style) — it cannot parse binary HTTP/2 frames used by gRPC
2. `realitySettings` has no `alpn` field, so `alpn: "h2"` fallback matching (the documented way to route HTTP/2) cannot be configured for Reality
3. The single `target` in Reality means all SNIs share one camouflage destination, creating a fingerprinting vector

TCP+Vision works because it speaks VLESS directly — no fallback needed. gRPC and xHTTP fail because their HTTP/2 data reaches the VLESS parser, which rejects it with `invalid request version`.

## Solution

Replace the single-inbound+fallbacks architecture with nginx `ssl_preread` SNI routing to three independent xray inbounds, each with its own Reality configuration and matching camouflage target.

## Architecture

```
                              ┌─ SNI: api.oneme.ru ──────────→ xray 127.0.0.1:9000
                              │                                 VLESS+TCP+Vision+Reality
client :443 → nginx stream ───┼─ SNI: avatars.mds.yandex.net ─→ xray 127.0.0.1:9001
               (ssl_preread)  │                                 VLESS+gRPC+Reality
                              └─ SNI: onlymir.ru ─────────────→ xray 127.0.0.1:9002
                                                                VLESS+xHTTP+Reality
```

- nginx operates at L4 (TCP) — never terminates TLS, never inspects application data
- Each xray inbound directly handles one transport with its own Reality TLS
- Each inbound's Reality `target` matches its SNI for consistent camouflage
- Shared `privateKey` and `shortIds` across all three inbounds
- The old single inbound on port 443 is completely removed — xray no longer binds to 443 directly

## Server Changes (`roles/network/xray/server.nix`)

### Options

Remove:
- `reality.fakeSni` — replaced by per-transport `sni`
- `vlessWs` — removed entirely (can be re-added later as a 4th SNI)

Add `vlessTcp.enable` (TCP+Vision was previously always-on as the main inbound; now it's optional like the others).

Add per-transport `sni` option:
```nix
vlessTcp = {
  enable = mkEnableOption "VLESS over direct TCP with Vision flow";
  sni = mkOption {
    type = types.str;
    default = "api.oneme.ru";
    description = "Reality SNI and target for TCP+Vision transport";
  };
};

vlessGrpc = {
  enable = mkEnableOption "VLESS over gRPC";
  sni = mkOption {
    type = types.str;
    default = "avatars.mds.yandex.net";
    description = "Reality SNI and target for gRPC transport";
  };
  serviceName = mkOption {
    type = types.str;
    default = "VlGrpc";
    description = "gRPC service name (no leading slash)";
  };
};

vlessXhttp = {
  enable = mkEnableOption "VLESS over xHTTP";
  sni = mkOption {
    type = types.str;
    default = "onlymir.ru";
    description = "Reality SNI and target for xHTTP transport";
  };
  path = mkOption {
    type = types.str;
    default = "/vl-xhttp";
    description = "xHTTP path";
  };
};
```

### Inbounds

Three independent inbounds replace the old single-inbound+fallbacks+sub-inbounds. The old main inbound on port 443 is completely removed.

```nix
# Port reassignment: 9000 was vlessWsPort, now vlessTcpPort (WS is removed)
vlessTcpPort = 9000;
vlessGrpcPort = 9001;
vlessXhttpPort = 9002;
```

Each inbound follows this pattern:
```json
{
  "listen": "127.0.0.1",
  "port": 9000,
  "protocol": "vless",
  "tag": "vless-tcp-in",
  "settings": {
    "clients": [{ "id": "UUID", "flow": "xtls-rprx-vision" }],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "target": "api.oneme.ru:443",
      "serverNames": ["api.oneme.ru"],
      "shortIds": ["..."],
      "privateKey": "INJECTED_AT_RUNTIME"
    }
  }
}
```

Key differences per transport:
- **TCP+Vision (9000):** `network = "tcp"`, clients have `flow = "xtls-rprx-vision"`, tag `"vless-tcp-in"`
- **gRPC (9001):** `network = "grpc"`, `grpcSettings.serviceName`, no flow on clients, tag `"vless-grpc-in"`
- **xHTTP (9002):** `network = "xhttp"`, `xhttpSettings.path`, no flow on clients, tag `"vless-xhttp-in"`

Removed from all inbounds:
- `fallbacks` — no longer needed
- `sockopt.acceptProxyProtocol` — nginx ssl_preread is transparent TCP, not proxy protocol
- `xver` — same reason

### Routing rules

Update inbound tags to match the new inbounds:
```nix
routing.rules = [{
  type = "field";
  inboundTag =
    lib.optionals cfg.vlessTcp.enable [ "vless-tcp-in" ]
    ++ lib.optionals cfg.vlessGrpc.enable [ "vless-grpc-in" ]
    ++ lib.optionals cfg.vlessXhttp.enable [ "vless-xhttp-in" ];
  outboundTag = "direct-out";
}];
```

### nginx SNI routing

Generated as part of `services.nginx.streamConfig` in `server.nix`. NixOS builds nginx with `--with-stream_ssl_preread_module` when `streamConfig` is non-empty, so `ssl_preread` is available. The existing `stream-forwarder.nix` on veles already uses `streamConfig` (port 8443), confirming stream module support.

```nginx
map $ssl_preread_server_name $xray_backend {
    api.oneme.ru            127.0.0.1:9000;
    avatars.mds.yandex.net  127.0.0.1:9001;
    onlymir.ru              127.0.0.1:9002;
    default                 127.0.0.1:9000;
}

server {
    listen 443;
    ssl_preread on;
    proxy_pass $xray_backend;
}
```

The `default` backend routes unknown SNIs to the TCP+Vision inbound, which will reject them at the Reality handshake (invalid serverName) — expected behavior, consistent with how the old single inbound handled probes.

This coexists with the existing `stream-forwarder.nix` config on veles (port 8443) since NixOS concatenates `streamConfig` strings.

Note: `common/server.nix` opens ports 80 and 443 when nginx is enabled, and also sets up an HTTP `virtualHosts.default` block. This is fine — the HTTP default virtualHost listens on port 80 (no explicit `listen 443`), so there is no conflict with the stream `listen 443`. Port 80 being opened is an acceptable side effect.

### Private key injection

The jq startup script must change from `inbounds[0]` to `inbounds[]` to inject `privateKey` into all three inbounds:

```bash
# OLD: .inbounds[0].streamSettings.realitySettings.privateKey = $key
# NEW: iterates all inbounds
jq --arg key "$KEY" \
  '.inbounds[].streamSettings.realitySettings.privateKey = $key' \
  template.json > /tmp/xray.json
```

## Client Changes (`roles/network/xray/client.nix`)

### Options

Add per-transport `serverName` option:
```nix
vlessTcp.serverName = mkOption {
  type = types.str;
  default = "";
  description = "Reality SNI for this transport (falls back to reality.serverName if empty)";
};
# Same for vlessGrpc.serverName, vlessXhttp.serverName
```

Keep shared `reality.serverName` as a default fallback for backwards compatibility.

Fix `vlessGrpc.serviceName` default from `"vl-grpc"` to `"VlGrpc"` to match server default.

Remove `vlessWs` options entirely.

### mkStreamSettings

Updated to prefer transport-level `serverName` over shared `reality.serverName`:

```nix
mkStreamSettings = transport:
  let
    sni = if transport.serverName != ""
          then transport.serverName
          else cfg.reality.serverName;
    securitySettings = if cfg.reality.enable then {
      security = "reality";
      realitySettings = {
        publicKey = cfg.reality.publicKey;
        shortId = cfg.reality.shortId;
        serverName = sni;
        fingerprint = cfg.reality.fingerprint;
      };
    } else { ... };
  in
  securitySettings // transport.extra;
```

## Machine Config Changes (`machines/veles/default.nix`)

```nix
roles.xray-server = {
  enable = true;
  reality.privateKeyFile = "/etc/nixos/secrets/veles-xray-reality.privkey";
  vlessTcp = {
    enable = true;
    sni = "api.oneme.ru";
  };
  vlessGrpc = {
    enable = true;
    sni = "avatars.mds.yandex.net";
  };
  vlessXhttp = {
    enable = true;
    sni = "onlymir.ru";
  };
};
```

Remove `reality.fakeSni`, `vlessWs.enable`.

## What Gets Removed

- The old single VLESS+TCP+Reality inbound on port 443 — xray no longer listens on 443 directly
- WS transport (`vlessWs`) — from both server and client
- Fallbacks — entirely gone
- Sub-inbounds pattern — replaced by direct Reality inbounds (same ports, new role)
- `acceptProxyProtocol` / `xver` — not needed with transparent TCP proxy
- `reality.fakeSni` — replaced by per-transport `sni`

## Firewall

- Port 443: kept in `server.nix` (`networking.firewall.allowedTCPPorts`). Also opened by `common/server.nix` when nginx is enabled (harmless duplicate, NixOS deduplicates).
- Ports 9000-9002: no firewall rules needed (localhost only)
- `common/server.nix`: unchanged
