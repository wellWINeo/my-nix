# Xray Relay Logic Design

## Goal

Add relay capability to the xray server module so a server can forward client
traffic to another xray server instead of (or in addition to) routing it
directly to the internet. The relay coexists with existing direct-serve
inbounds on the same machine.

## Module Structure

```
roles/network/xray/
├── default.nix    # Coordinator: top-level roles.xray option, merges configs,
│                  #   owns systemd service, nginx stream, firewall, assertions
├── options.nix    # Shared transport option helpers (used by client.nix & relay.nix)
├── server.nix     # Defines roles.xray.server.*, exports _serverConfig fragment
├── client.nix     # Defines roles.xray.client.*, runs own xray process (independent)
└── relay.nix      # Defines roles.xray.relay.*, exports _relayConfig fragment
```

## Option API

### Top-level

```nix
roles.xray = {
  enable = mkEnableOption "xray proxy";
};
```

### Server (`server.nix`)

Unchanged from current `roles.xray-server` options, just re-rooted under
`roles.xray.server`:

```nix
roles.xray.server = {
  enable = mkEnableOption "...";
  reality.privateKeyFile = mkOption { ... };
  vlessTcp = { enable; sni; };
  vlessGrpc = { enable; sni; serviceName; };
  vlessXhttp = { enable; sni; path; };
};
```

Exports `roles.xray._serverConfig` (internal option):

- **Inbounds:** `vless-tcp-in` (port 9000), `vless-grpc-in` (port 9001),
  `vless-xhttp-in` (port 9002) -- same as today.
- **Outbounds:** `direct-out` (freedom).
- **Routing rules:** all server inbound tags -> `direct-out`.
- **Nginx SNI entries:** server SNIs -> server ports.

### Client (`client.nix`)

Unchanged from current `roles.xray-client`, re-rooted under
`roles.xray.client`. Uses shared helpers from `options.nix` for transport
option definitions. Runs its **own independent xray process** -- no config
merging with server/relay.

```nix
roles.xray.client = {
  enable = mkEnableOption "...";
  port = mkOption { ... };
  openFirewall = mkOption { ... };
  reality = { enable; publicKey; shortId; serverName; fingerprint; };
  vlessTcp = { enable; server; port; auth = { name; uuid; }; serverName; };
  vlessGrpc = { enable; server; port; auth; serverName; serviceName; };
  vlessXhttp = { enable; server; port; auth; serverName; path; };
};
```

### Relay (`relay.nix`)

```nix
roles.xray.relay = {
  enable = mkEnableOption "...";

  # Credentials for authenticating to the target server
  user = mkOption {
    type = types.attrs;  # { uuid, name, ... } from secrets.singBoxUsers
  };

  # Target server connection (reuses option helpers from options.nix)
  target = {
    server = mkOption { type = types.str; };  # target IP/hostname
    reality = { enable; publicKey; shortId; fingerprint; serverName; };
    vlessTcp = { enable; serverName; };
    vlessGrpc = { enable; serverName; serviceName; };
    vlessXhttp = { enable; serverName; path; };
  };

  # Relay's own inbound SNIs (distinct from server SNIs, for nginx routing)
  vlessTcp.sni = mkOption { type = types.str; };
  vlessGrpc.sni = mkOption { type = types.str; };
  vlessXhttp.sni = mkOption { type = types.str; };
};
```

`target` transport options share definitions with `client.nix` via
`options.nix`. The shared helpers accept a parameter to control which options
are generated -- relay's `target` transports omit per-transport `server`,
`port`, and `auth` options since relay uses a single `target.server` (always
port 443) and a single `user` for all transports.

`user` provides the UUID for all relay outbounds -- no need to repeat
`auth.uuid` per transport.

Exports `roles.xray._relayConfig` (internal option):

- **Inbounds:** `vless-tcp-fwd-in` (port 9010), `vless-grpcFwd-in`
  (port 9011), `vless-xhttp-fwd-in` (port 9012). Same Reality settings,
  client lists, and ProxyProtocol as server inbounds, but with relay-specific
  SNIs. Only created for transports enabled on both server and relay.
- **Outbounds:** `relay-tcp-out`, `relay-grpc-out`, `relay-xhttp-out` --
  VLESS connections to the target server using the configured transports.
- **Routing:** relay inbound tags -> `relay-balancer`.
- **Balancer:** `relay-balancer` with `leastPing` strategy, selecting among
  enabled relay outbounds.
- **Nginx SNI entries:** relay SNIs -> relay ports.

## Shared Options (`options.nix`)

Exports helper functions that generate NixOS option definitions for transport
configuration. Used by both `client.nix` and `relay.nix` to avoid
duplicating option definitions.

```nix
{ lib }:
{
  mkRealityOptions = { defaults ? {} }: { ... };
  mkVlessTcpOptions = { defaults ? {} }: { ... };
  mkVlessGrpcOptions = { defaults ? {} }: { ... };
  mkVlessXhttpOptions = { defaults ? {} }: { ... };
}
```

Each function returns an attribute set of NixOS options (enable, server,
port, auth, serverName, etc.). `defaults` allows callers to override default
values (e.g., relay doesn't need per-transport `server`/`port`).

## Config Merging (`default.nix`)

`default.nix` is the single coordinator. It:

1. **Imports** `server.nix`, `client.nix`, `relay.nix`.
2. **Defines** `roles.xray.enable` and internal options (`_serverConfig`,
   `_relayConfig`).
3. **Merges** server + relay config fragments into one xray JSON config:
   ```nix
   xrayConfig = {
     log = { loglevel = "info"; };
     inbounds = serverConfig.inbounds ++ relayConfig.inbounds;
     outbounds = serverConfig.outbounds ++ relayConfig.outbounds;
     routing = {
       rules = serverConfig.routing.rules ++ relayConfig.routing.rules;
       balancers = relayConfig.routing.balancers;
     };
   };
   ```
4. **Owns systemd service:** writes config template, injects Reality private
   key at runtime via `LoadCredential` + `jq`, exec xray.
5. **Owns nginx stream config:** merges server SNI entries + relay SNI
   entries into one `map $ssl_preread_server_name` block.
6. **Owns firewall:** opens port 443.
7. **Assertions:**
   - `relay.enable` requires `server.enable`.
   - `server.enable || client.enable` (at least one sub-role when xray is
     enabled).
   - `server.enable && client.enable` is forbidden (same host conflict).
   - Relay transports must be a subset of server transports (can't relay gRPC
     if gRPC inbound isn't enabled on the server).
   - At least one server transport enabled.
   - Reality shortIds non-empty.

## Relay Data Flow

```
Client -> nginx:443 (SNI: relay-sni) -> relay inbound :901x
  -> routing (fwd tag) -> relay-balancer (leastPing)
  -> relay-{tcp,grpc,xhttp}-out -> target xray server:443
  -> target's direct-out -> internet
```

Direct traffic is unaffected:

```
Client -> nginx:443 (SNI: server-sni) -> server inbound :900x
  -> routing (direct tag) -> direct-out -> internet
```

## Inbound Naming Convention

| Transport | Server tag       | Relay tag             |
|-----------|------------------|-----------------------|
| TCP       | `vless-tcp-in`   | `vless-tcp-fwd-in`   |
| gRPC      | `vless-grpc-in`  | `vless-grpcFwd-in`   |
| xHTTP     | `vless-xhttp-in` | `vless-xhttp-fwd-in` |

## Port Allocation

| Transport | Server port | Relay port |
|-----------|-------------|------------|
| TCP       | 9000        | 9010       |
| gRPC      | 9001        | 9011       |
| xHTTP     | 9002        | 9012       |

## Host Migration

Machines change from:

```nix
imports = [ ../../roles/network/xray/server.nix ];
roles.xray-server = { enable = true; ... };
```

To:

```nix
imports = [ ../../roles/network/xray ];
roles.xray = {
  enable = true;
  server = { enable = true; ... };
};
```

Example with relay (e.g., veles relaying to buyan):

```nix
roles.xray = {
  enable = true;
  server = {
    enable = true;
    reality.privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
    vlessTcp = { enable = true; sni = "api.oneme.ru"; };
    vlessGrpc = { enable = true; sni = "avatars.mds.yandex.net"; };
    vlessXhttp = { enable = true; sni = "onlymir.ru"; };
  };
  relay = {
    enable = true;
    user = secrets.singBoxUsers.someUser;
    target = {
      server = secrets.ip.buyan.address;
      reality = { enable = true; publicKey = "..."; shortId = "..."; };
      vlessTcp = { enable = true; serverName = "ghcr.io"; };
      vlessGrpc = { enable = true; serverName = "update.googleapis.com"; };
      vlessXhttp = { enable = true; serverName = "dl.google.com"; };
    };
    vlessTcp.sni = "relay-tcp.example.com";
    vlessGrpc.sni = "relay-grpc.example.com";
    vlessXhttp.sni = "relay-xhttp.example.com";
  };
};
```
