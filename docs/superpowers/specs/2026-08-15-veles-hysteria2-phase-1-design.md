# Veles Hysteria2 Phase-1 Hardening — Design Spec

## Goal

Expose Hysteria2 only on **veles** as a single UDP/443 entry point, give
unauthenticated HTTP/3 probes a reverse-proxied response rather than Xray's
default 404 page, and retain the existing VLESS/REALITY relay path to Buyan.

## Scope

- Configure a Hysteria2 relay inbound on Veles at UDP/443 only.
- Remove/disable the Hysteria2 server inbound on Buyan.
- Add HTTP/3 masquerade on Veles by proxying to
  `https://turn.webrtc.yandex.net`.
- Continue using the existing self-signed Veles certificate and key.
- Keep `roles.xray.relay.target.hysteria.enable = false`.

Out of scope: an upstream Hysteria daemon, Hysteria obfuscation/ECH, automatic
certificate generation or rotation, client subscription serving, and a Buyan
Hysteria2 endpoint.

## Architecture

```text
Hysteria client
  └─ UDP/443; SNI turn.webrtc.yandex.net; certificate SHA-256 pin
       └─ Veles Xray Hysteria2 relay inbound
            ├─ unauthenticated HTTP/3 → HTTPS proxy to turn.webrtc.yandex.net
            └─ authenticated traffic → existing relay balancer
                 → VLESS/REALITY → Buyan
```

TCP/443 remains independently owned by the existing TCP SNI router. UDP and
TCP can share numeric port 443, so this change does not modify that router.

## Configuration design

### Veles

`roles.xray.relay.hysteria` remains the only enabled Hysteria2 inbound. Its
`port` becomes `443`, and it receives:

```nix
masquerade = {
  type = "proxy";
  url = "https://turn.webrtc.yandex.net";
};
```

`rewriteHost` is deliberately left absent (Xray default `false`). The intended
client/probe request authority is already `turn.webrtc.yandex.net`; rewriting
is only needed to make arbitrary Host/:authority values appear as that target.

The existing certificate and key paths remain unchanged. The client-facing SNI
remains `turn.webrtc.yandex.net`, per the approved deployment choice.

### Buyan

Remove the Hysteria2 server configuration so the role no longer creates a
Hysteria inbound or opens UDP/36712. The existing VLESS/REALITY server remains
unchanged.

### Certificate pinning

A server does not pin its own certificate. `pinSHA256` is consumed by Hysteria
clients, such as an exported `hysteria2://` URI or an enabled relay Hysteria
outbound; neither exists in Phase 1. Therefore the implementation must not
insert a literal placeholder in a functional `pinSHA256` field.

After the self-signed certificate is deployed, an operator calculates its
actual SHA-256 certificate pin and distributes it through the trusted client
configuration channel. Client configuration must use that real pin, not
`insecure=1`. The pin value must be replaced on every certificate rotation.

## Security and detection trade-off

Pinning a self-signed certificate protects participating Hysteria clients from
certificate substitution once they received the pin through a trusted channel.
It does not make the endpoint indistinguishable from ordinary public HTTPS:
an active probe can observe a self-signed certificate claiming the third-party
SNI `turn.webrtc.yandex.net`. The reverse-proxy masquerade improves the
unauthenticated HTTP/3 response over the default 404 page but does not remove
this certificate/SNI signal. A future phase should use a domain controlled by
the operator and a publicly trusted certificate if normal-web camouflage is a
requirement.

## Validation

1. Evaluate the Veles and Buyan NixOS configurations and format changed Nix
   files with `nixfmt`.
2. Deploy Veles and verify `xray` listens on UDP/443; verify UDP/36712 is no
   longer open. Verify Buyan no longer has a Hysteria listener.
3. From an external host, make an unauthenticated HTTP/3 request with
   `turn.webrtc.yandex.net` as SNI and authority. It must return proxied
   content rather than the Hysteria/Xray default 404 response.
4. Calculate the deployed certificate's SHA-256 pin. Test a Hysteria client
   with that pin and verify it can relay traffic through Veles to Buyan.
5. Change one pin character in a test client and verify the connection fails.
6. Confirm the existing VLESS/REALITY endpoints and Veles-to-Buyan relay
   behavior remain operational.

## Failure handling

- If the masquerade target rejects the proxy request or returns an unsuitable
  response, disable the masquerade change and investigate with an HTTP/3
  request before exposing the endpoint.
- If the certificate pin does not match, fail client connection setup; do not
  replace the failure with `insecure=1`.
- If UDP/443 conflicts with another UDP listener, resolve that conflict rather
  than falling back to a second Hysteria port in this phase.
