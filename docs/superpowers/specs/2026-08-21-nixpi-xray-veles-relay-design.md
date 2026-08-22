# Nixpi Xray-to-Veles Relay Design

## Goal

Replace nixpi's active Sing-box client configuration with Xray so LAN clients can use unauthenticated HTTP and SOCKS5 proxies, with traffic travelling through Veles's Xray relay and then Buyan:

```text
[LAN client] -- HTTP/SOCKS5 --> nixpi -- VLESS/Reality --> veles -- VLESS/Reality --> buyan --> internet
```

The reusable Sing-box module remains in the repository; only nixpi stops enabling it.

## Architecture

Nixpi will run `roles.xray.client` and expose two unauthenticated TCP listeners on all interfaces:

| Protocol | Address | Port |
| --- | --- | --- |
| SOCKS5 | `0.0.0.0` | `1081` |
| HTTP proxy | `0.0.0.0` | `3128` |

Nixpi's firewall will open both ports. This intentionally exposes unauthenticated proxies to hosts that can reach nixpi, so deployment is appropriate only on the trusted LAN.

Both inbounds route exclusively through an Xray balancer over three VLESS+Reality outbounds. Each outbound dials `secrets.ip.veles.address:443` and authenticates with the configured proxy user. The client enables TCP+Vision, gRPC, and xHTTP.

The transport-specific SNI values deliberately select Veles's **relay** inbounds, not its direct server inbounds:

| Transport | Veles relay SNI |
| --- | --- |
| TCP+Vision | `api.oneme.ru` |
| gRPC | `avatars.mds.yandex.net` |
| xHTTP | `onlymir.ru` |

Veles's existing Xray relay maps those inbounds to its VLESS+Reality outbounds targeting Buyan. Buyan's existing Xray server then exits to the Internet. No Veles or Buyan configuration changes are required.

## Xray Client Module Changes

`roles/network/xray/client.nix` will retain its existing SOCKS5 `port` option (default `1081`) and add an opt-in HTTP inbound:

```nix
http = {
  enable = false;
  port = 3128;
};
```

When `http.enable` is true, the generated Xray settings include an unauthenticated `http` inbound at `0.0.0.0:<port>`. The existing SOCKS5 inbound remains unauthenticated at `0.0.0.0:<port>`. `openFirewall` opens the SOCKS port and, when enabled, the HTTP port.

The client uses an Xray `leastPing` balancer rather than random selection. Xray observatory probes apply only to enabled VLESS transport outbounds, so `direct-out` is never chosen. An unavailable transport is retried by the observatory and becomes eligible again after it is healthy.

Existing hosts using the Xray client remain compatible: HTTP is disabled by default, while the SOCKS5 option and default port remain unchanged.

## Nixpi Configuration Changes

`machines/nixpi/default.nix` will:

1. remove `nixpiSingBoxUser` and the complete `roles.sing-box-client` block;
2. define a local Xray proxy user from `secrets.singBoxUsers`;
3. enable `roles.xray.client` with SOCKS5 and HTTP listeners;
4. enable TCP+Vision, gRPC, and xHTTP outbounds to `secrets.ip.veles.address` on port `443`;
5. set the Veles relay SNI values above and the matching default gRPC service name (`VlGrpc`) and xHTTP path (`/vl-xhttp`);
6. provide Veles's Reality public key, an authorized short ID, and `chrome` fingerprint.

`secrets.xray.reality.publicKey` is confirmed to be Veles's Reality public key and will be used by nixpi. Nixpi uses the existing configured short ID from `secrets.xray.reality.shortIds`.

## Secrets and Dummy Evaluation

The real deployed secret data must expose Veles's address at `secrets.ip.veles.address`. `secrets/secrets.dummy.json` will receive a fake `ip.veles.address` (and gateway for consistency with the existing host IP records) so flake evaluation with dummy secrets succeeds.

No private key is added to Nix source or the Nix store.

## Validation

Before deployment:

1. Run `nixfmt` for every modified Nix file.
2. Prepare dummy secrets if required: `make setup-dummy-secrets`.
3. Evaluate/build nixpi with `nix build .#nixosConfigurations.nixpi.config.system.build.toplevel --dry-run`.
4. Run `make check`.
5. Inspect the evaluated Xray settings to verify two inbounds, three VLESS outbounds, observatory configuration, and a `leastPing` balancer.

After deployment on nixpi:

1. Verify the HTTP and SOCKS5 listeners with `ss -ltnp`.
2. Send an HTTP-proxy request with `curl -x http://127.0.0.1:3128 https://ifconfig.me`.
3. Send a SOCKS5-proxy request with `curl --socks5-hostname 127.0.0.1:1081 https://ifconfig.me`.
4. Inspect `journalctl -u xray` to confirm Xray establishes a VLESS connection to Veles and failover/recovery behavior is observable.
