# Xray Reality on Veles — Design Spec

**Goal:** Transform the existing xray server/client modules to use Reality TLS with Vision flow, add xHTTP transport, and deploy on veles with `api.oneme.ru` as the fake SNI. All three VLESS transports (WS, gRPC, xHTTP) plus direct TCP+Vision share port 443 via Xray's fallback mechanism.

## Architecture

Single port 443 with Xray handling TLS via Reality (no nginx, no ACME needed for proxy):

```
Client connects to veles:443
  └─ Reality TLS handshake (mimics api.oneme.ru)
      ├─ Invalid shortId → Reality forwards to real api.oneme.ru:443 (via realitySettings.target)
      └─ Valid shortId → decrypt
          ├─ VLESS protocol → direct TCP + Vision (flow: xtls-rprx-vision)
          ├─ HTTP + path /vl-ws → VLESS fallback to localhost:9000 (WS inbound)
          ├─ HTTP/2 + gRPC path → VLESS fallback to localhost:9001 (gRPC inbound)
          ├─ HTTP + path /vl-xhttp → VLESS fallback to localhost:9002 (xHTTP inbound)
          └─ Other non-VLESS traffic → connection closed (no default fallback)
```

**Key distinction:** Reality's `target` field handles unauthorized connections (bad shortId) at the TLS level. VLESS `fallbacks` handle authorized-but-non-VLESS traffic (WS/gRPC/xHTTP) after decryption. These are two separate mechanisms.

- Reality steals `api.oneme.ru`'s TLS fingerprint — probers see an identical response to the real site
- Vision (`xtls-rprx-vision`) optimizes TLS-in-TLS for direct TCP connections only
- WS/gRPC/xHTTP use framed transports — no Vision flow on these paths
- Private key never enters the Nix store — injected at runtime via preStart script
- No nginx or ACME needed — the `letsencrypt` role import can be removed from veles

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `roles/network/xray/server.nix` | Modify | Replace nginx+TLS with Reality, add xHTTP, add fallback routing |
| `roles/network/xray/client.nix` | Modify | Add Reality security, xHTTP outbound, direct TCP+Vision outbound |
| `machines/veles/default.nix` | Modify | Import xray server, configure Reality with all transports |

## Server Module (`roles/network/xray/server.nix`)

### Options Changes

**Remove:**
- `baseDomain` — no longer needed (no ACME/nginx)
- `enableFallback` — replaced by Reality's built-in fallback to fakeSni

**Add:**
- `reality.privateKeyFile` (types.path) — path to private key file on disk
- `reality.fakeSni` (types.str) — target server to impersonate, default `"api.oneme.ru"`
- `vlessXhttp.enable` (mkEnableOption)
- `vlessXhttp.path` (types.str, default `"/vl-xhttp"`)

**Keep:**
- `enable`, `vlessWs.enable`, `vlessWs.path`, `vlessGrpc.enable`, `vlessGrpc.serviceName`

### Config Generation

**Main inbound** (port 443, VLESS + Reality):
```json
{
  "port": 443,
  "protocol": "vless",
  "tag": "vless-reality-in",
  "settings": {
    "clients": [
      { "id": "<uuid>", "flow": "xtls-rprx-vision", "email": "<name>@xray" }
    ],
    "decryption": "none",
    "fallbacks": [
      { "path": "/vl-ws", "dest": 9000, "xver": 1 },
      { "path": "/vl-grpc", "dest": 9001, "xver": 1 },
      { "path": "/vl-xhttp", "dest": 9002, "xver": 1 }
    ]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "target": "api.oneme.ru:443",
      "serverNames": ["api.oneme.ru"],
      "privateKey": "<INJECTED_AT_RUNTIME>",
      "shortIds": ["<from secrets.xrayRealityShortIds>"]
    }
  }
}
```

No default fallback entry — unauthorized connections are handled by `realitySettings.target`, and unmatched post-decryption traffic is simply closed.

**Note on gRPC fallback routing:** gRPC uses HTTP/2 frames. Xray's fallback `path` matching does prefix matching on the HTTP request path. A gRPC request to service `vl-grpc` produces path `/vl-grpc/Tun` (or similar), which matches the fallback `path: "/vl-grpc"` prefix. If this proves unreliable in practice, an alternative is `alpn`-based routing (`"alpn": "h2"` for the gRPC fallback entry), but this conflicts if xHTTP also negotiates h2. To be verified during deployment.

**Internal inbounds** (localhost, no TLS, no flow):
- WS on 127.0.0.1:9000 — `network: "ws"`, `wsSettings.path`, `sockopt.acceptProxyProtocol: true`
- gRPC on 127.0.0.1:9001 — `network: "grpc"`, `grpcSettings.serviceName`, `sockopt.acceptProxyProtocol: true`
- xHTTP on 127.0.0.1:9002 — `network: "xhttp"`, `xhttpSettings.path`, `sockopt.acceptProxyProtocol: true`

All internal inbounds must set `acceptProxyProtocol: true` because the fallback entries use `xver: 1` (PROXY protocol v1). Each internal inbound has its own client list (same UUIDs from `secrets.singBoxUsers`, no flow).

**shortIds** are read from `secrets.xrayRealityShortIds` (array of strings in secrets.json) via the existing `secrets = import ../../../secrets` pattern.

### Runtime Key Injection

Remove nginx integration entirely. Use `services.xray.settingsFile` instead of `services.xray.settings` to control the config path:

1. Generate a template JSON config in the Nix store (with `"privateKey": "__XRAY_PRIVATE_KEY__"` placeholder)
2. Add a systemd `ExecStartPre` script that:
   - Reads the template config
   - Reads the private key from `reality.privateKeyFile`
   - Uses `jq` to replace the placeholder: `.inbounds[0].streamSettings.realitySettings.privateKey = $key`
   - Writes final config to `/run/xray/config.json`
3. Set `services.xray.settingsFile = "/run/xray/config.json"`
4. Add `RuntimeDirectory = "xray"` to the systemd service

### Firewall

Open TCP 443.

### Assertions

- `vlessGrpc.serviceName` must not start with `/`
- `reality.privateKeyFile` must be set
- No transport assertion needed — the main inbound always handles direct TCP+Vision regardless of whether WS/gRPC/xHTTP are enabled

## Client Module (`roles/network/xray/client.nix`)

### Options Changes

**Add shared Reality block at `roles.xray-client` level:**
- `reality.enable` (mkEnableOption) — use Reality instead of regular TLS for all transports
- `reality.publicKey` (types.str) — server's Reality public key (from `secrets.xrayRealityPublicKey`)
- `reality.shortId` (types.str) — authorized shortId (from `secrets.xrayRealityShortIds`)
- `reality.serverName` (types.str) — SNI to present (e.g., `"api.oneme.ru"`)
- `reality.fingerprint` (types.str, default `"chrome"`) — uTLS fingerprint

When `reality.enable = true`, all outbounds use `security: "reality"` with the shared settings. When false, they use `security: "tls"` (backwards compatible with existing nginx+TLS servers).

**Add new transport:**
- `vlessXhttp` — same structure as vlessWs/vlessGrpc (enable, server, port, auth, path)

**Add direct TCP+Vision:**
- `vlessTcp.enable`, `.server`, `.port`, `.auth` — direct VLESS connection with `flow: "xtls-rprx-vision"` (set ONLY on this outbound's user object)

### Outbound Generation

Each enabled transport generates a VLESS outbound with appropriate streamSettings:
- `security` field set to `"tls"` or `"reality"` based on `reality.enable`
- When `"reality"`: include `realitySettings` with publicKey, shortId, serverName, fingerprint from the shared block
- TCP outbound: `flow: "xtls-rprx-vision"` on the user object
- WS/gRPC/xHTTP outbounds: NO flow on the user object

### Balancer

Add `vless-xhttp-out` and `vless-tcp-out` to the selector list alongside existing WS/gRPC tags.

## Veles Machine Config (`machines/veles/default.nix`)

```nix
imports = [
  # ... existing imports ...
  ../../roles/network/xray/server.nix
  # Remove: ../../roles/letsencrypt.nix (no longer needed without nginx/ACME)
];

roles.xray-server = {
  enable = true;
  reality = {
    privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
    fakeSni = "api.oneme.ru";
  };
  vlessWs.enable = true;
  vlessGrpc.enable = true;
  vlessXhttp.enable = true;
};
```

Remove `roles.letsencrypt` config (no longer needed — Reality doesn't use ACME certificates).

Existing stream-forwarder (8443 → mokosh:443) remains unchanged.

## Secrets Setup (Manual)

Before deploying:
1. Generate Reality keypair on veles: `xray x25519`
2. Add to `secrets.json`: `xrayRealityPublicKey` (string), `xrayRealityShortIds` (array of strings)
3. Save private key to `/etc/nixos/secrets/xray-reality-private-key` on veles
4. Run `make lock` to re-encrypt

## Out of Scope

- Nixpi client config (deploy separately after server verification)
- Mokosh changes (unaffected)
- Removing existing sing-box modules
