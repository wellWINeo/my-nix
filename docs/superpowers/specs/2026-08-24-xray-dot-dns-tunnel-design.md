# Xray-carried DNS-over-TLS tunnel design

## Goal

Keep the existing nixpi local recursive DNS service available when direct DNS-over-TLS (DoT) is blocked by DPI. CoreDNS continues to authenticate and encrypt its connection to the DNS provider, while Xray carries the provider TCP connection through the existing VLESS proxy client.

The resolution priority is:

1. Cloudflare DoT directly (`1.1.1.1`, then `1.0.0.1`)
2. Cloudflare DoT via an Xray TCP tunnel (`127.0.0.1:5053` to `1.1.1.1:853`)
3. Google DoT directly (`8.8.8.8`, then `8.8.4.4`)
4. Existing plaintext provider-DNS fallback

## Scope

- Add reusable TCP tunnels to `roles.xray.client`.
- Route every tunnel through the existing Xray `proxy-balancer` and its configured VLESS transports.
- Configure the first tunnel and the CoreDNS priority chain on nixpi.
- Make the outer CoreDNS fallback layer advance when a nested provider block returns `SERVFAIL` or `REFUSED`.

Firewall behavior for tunnel listeners is deliberately out of scope. A tunnel binds exactly to its configured address; opening an externally reachable listener remains an explicit machine-level firewall decision.

## Xray tunnel interface

`roles.xray.client.tunnels` is a list with an empty default. Each entry has this public interface:

```nix
tunnels = [
  {
    listen = "127.0.0.1:5053";
    target = "1.1.1.1:853";
  }
];
```

`listen` is the local address and TCP port on which Xray accepts connections. It may be a loopback address or another local address, such as `192.168.0.20:1234`. `target` is the fixed remote TCP destination that Xray carries over VLESS.

The module parses and validates endpoint syntax and port ranges, rejects duplicate listeners, and generates one Xray `dokodemo-door` TCP inbound per entry. Each inbound has a unique tag and a routing rule selecting the existing `proxy-balancer`. Tunnels do not change SOCKS, HTTP proxy, VLESS transport, or firewall configuration.

Xray is a TCP carrier only. It does not terminate, inspect, or authenticate DoT TLS.

## CoreDNS configuration

The existing three local CoreDNS forwarding blocks remain:

```text
:53 → :9055 Cloudflare → :9057 Google → :9058 plaintext DNS
```

The Cloudflare block at `:9055` receives a third, sequential DoT endpoint:

```caddyfile
forward . tls://1.1.1.1 tls://1.0.0.1 tls://127.0.0.1:5053 {
  tls_servername cloudflare-dns.com
  policy sequential
  health_check 5s
  max_fails 2
}
```

This causes CoreDNS to first attempt direct Cloudflare DoT, then establish a DoT TLS connection through the local Xray tunnel. `tls_servername cloudflare-dns.com` remains required for SNI and certificate verification; the remote TLS peer is still Cloudflare.

The outer port-53 forwarder retains its sequential upstream order and adds:

```caddyfile
failover SERVFAIL REFUSED
```

`failfast_all_unhealthy_upstreams` remains enabled. It only sends an immediate `SERVFAIL` after every outer fallback endpoint is considered unhealthy.

## Failure behavior

A nested CoreDNS forwarding block can return a DNS `SERVFAIL` when its remote DoT exchange fails. Without `failover`, the outer forwarder treats that as a received DNS response and returns it to the client instead of trying the next local provider block. It also treats a non-network DNS response as healthy for health-check purposes.

Adding `failover SERVFAIL REFUSED` makes those error responses advance through the intended provider chain. A direct Cloudflare failure therefore tries the tunneled Cloudflare endpoint; if the Cloudflare block cannot answer, CoreDNS tries Google DoT and finally plaintext DNS. If every outer endpoint is unhealthy, `failfast_all_unhealthy_upstreams` returns `SERVFAIL` promptly.

`SERVFAIL` and `REFUSED` can be legitimate resolver responses, so this policy intentionally favors client availability over preserving a specific resolver's error response.

## Validation

1. Format changed Nix files with `nixfmt`.
2. Run `make setup-dummy-secrets` when required, then `make check`.
3. After nixpi deployment, confirm `xray` and `coredns` are active.
4. Use a DoT-capable client against `127.0.0.1:5053`, specifying `cloudflare-dns.com` as the TLS server name, to prove the raw TLS stream reaches Cloudflare through VLESS.
5. Query the normal CoreDNS service on port 53. Inspect CoreDNS and Xray journals when diagnosing a fallback event.
