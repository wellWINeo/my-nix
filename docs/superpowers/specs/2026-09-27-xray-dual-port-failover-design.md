# Xray Dual-Port Reachability and Failover Design

## Goal

Use Xray from the unstable nixpkgs input on the three Xray-enabled NixOS hosts, and provide a second TCP path on port 2053 while keeping the existing 443 listeners and Xray inbound counts unchanged. Veles and NixPi should health-select between Xray outbounds targeting the two ports.

## Base topology

This extends the existing NixPi → Veles → Buyan Xray relay described in [`2026-08-21-nixpi-xray-veles-relay-design.md`](2026-08-21-nixpi-xray-veles-relay-design.md):

```text
NixPi -- VLESS/Reality --> Veles -- VLESS/Reality --> Buyan --> Internet
```

## Approved design

### Package source

- Buyan, Veles, and NixPi use `xray` from `nixpkgs-unstable`.
- Every other package on those systems remains from the stable `nixpkgs` input.

### Public backup port

- TCP/2053 is redirected by the host firewall to the existing local TCP/443 SNI-router listener on both Buyan and Veles.
- Keep the single existing Nginx stream service and its listener on TCP/443. Do not add an Nginx listener on TCP/2053 or a second Nginx instance.
- Do not add duplicate Xray server inbounds. Both public ports reach the existing SNI map and existing Xray inbound set after the redirect.
- Keep this redirect TCP-only. Veles's Hysteria2 UDP/443 listener is unchanged.

### Health-aware outbound selection

- Veles has a primary and backup VLESS outbound for each enabled transport, targeting Buyan on TCP/443 and TCP/2053 respectively. Its existing `relay-balancer` and observatory cover both candidates.
- NixPi has a primary and backup VLESS outbound for each enabled transport, targeting Veles on TCP/443 and TCP/2053 respectively. Its existing `proxy-balancer` and observatory cover both candidates.
- Preserve the existing `leastPing` strategy and 60-second observatory interval. Selection is health-aware and may prefer whichever healthy candidate has lower observed latency; it is not strict primary-first failover. Existing streams are not migrated when a path fails.

### Subscriptions and scope

- Leave the subscription generator unchanged. Generated links continue to use TCP/443; TCP/2053 does not appear in subscriptions.
- Do not change SNI values, transport protocols, user credentials, DNS, or the Veles Hysteria2 UDP path.
- Do not commit or deploy without a separate user request.

## Implementation assumption to confirm

The implementation plan uses an IPv4 `iptables` redirect, matching Buyan's explicit IPv4 interface configuration and Veles's disabled IPv6 configuration. Confirm before implementation if an IPv6-facing backup endpoint is also required.

## Limitations

The repository contains no declaration of TCP/2053, but that does not establish live-host availability. Verify the port is available in the provider firewall and on both hosts before deployment. Since TCP/2053 redirects to the same TCP/443 service, it provides an alternate network path/port, not an independently isolated Xray or Nginx backend.