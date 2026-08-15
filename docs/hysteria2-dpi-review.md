# Hysteria 2 DPI-resistance review

**Scope and evidence.** This is a documentation/source review, not a traffic test or a configuration change. Sources are limited to Hysteria's current first-party documentation/protocol and `apernet/hysteria` upstream releases. The repository implements its Hysteria2 inbounds through **Xray**, not the upstream `hysteria` binary (`roles/network/xray/hysteria.nix`); therefore upstream YAML option names and feature availability must **not** be copied into this Nix/Xray configuration without verifying Xray's own implementation.

## Executive conclusion

**Documented facts:** Hysteria's normal mode is standard QUIC/HTTP/3 and its protocol says an unauthenticated/failed-auth connection should behave as a real HTTP/3 site. The project explicitly recommends serving authentic content or reverse-proxying a site to reduce active-probe response-pattern detection; absent masquerade it returns HTTP 404. Obfuscation is an alternative for networks that block QUIC/HTTP/3 while allowing UDP, but it intentionally stops the endpoint from being a valid standard QUIC/HTTP/3 server.

**Best-effort operational inference:** Choose one coherent observable: (a) normal HTTP/3 on UDP/443, a certificate/SNI that genuinely belongs together, and a working HTTP/3/TCP web presence; or (b) obfuscated UDP when plain QUIC is blocked. Combining obfuscation with HTTP/3 web masquerading undermines the latter's probe-facing benefit. Neither mode is documented as universally DPI-proof; they address different classifiers/blocking policies.

## Documented facts and operational implications

1. **TLS certificate, SNI, and ECH.** The server accepts either `tls` (certificate/key) or ACME. `sniGuard: strict` rejects an SNI that does not match the certificate; default `dns-san` enforces that only when the certificate has a DNS SAN. Certificates are loaded at every TLS handshake, so certificate files can be replaced without a server restart. [Full Server Config — TLS](https://hysteria.network/docs/advanced/Full-Server-Config/#tls)
   - **Inference:** use a publicly valid certificate whose DNS SAN matches the actual client SNI, rather than selecting an unrelated popular-domain SNI. This preserves normal TLS validation and reduces obvious certificate/SNI inconsistency. The current repository sets `sni = "bing.com"` on buyan and `sni = "turn.webrtc.yandex.net"` on veles, but the secret certificate SANs cannot be inspected here; treat certificate/SNI mismatch as a **high-severity conditional risk**, not a confirmed defect.
   - ECH encrypts the real ClientHello/SNI and exposes a configured public-name (decoy) SNI. The project says it only protects SNI, is most useful for bare/normal QUIC, adds no benefit when obfuscation already makes the connection unrecognizable as QUIC, and allows non-ECH clients to continue leaking cleartext SNI. ECH clients fail closed if it is rejected. [ECH](https://hysteria.network/docs/advanced/ECH/)

2. **HTTP/3 masquerade and active probing.** The protocol says that, to parties without credentials (including active probers), the server should behave as a standard HTTP/3 server and the encrypted traffic appears indistinguishable from normal HTTP/3. It requires an HTTP/3 server and says implementations should advise actual content or reverse proxying to avoid common Hysteria response patterns. Failed authentication must be handled as a normal site/forwarded upstream response. [Protocol — authentication & masquerading](https://hysteria.network/docs/developers/Protocol/#authentication--http3-masquerading)
   - Available upstream modes are static `file`, reverse `proxy`, and fixed `string`; the project says the proxy's `rewriteHost` is required when the upstream uses Host routing. With no masquerade, all HTTP requests get `404 Not Found`. [Full Server Config — Masquerade](https://hysteria.network/docs/advanced/Full-Server-Config/#masquerade)
   - HTTP/3 sites commonly pair UDP 443 with TCP HTTP/HTTPS on 80/443; upstream optionally provides `listenHTTP`, `listenHTTPS`, and `forceHTTPS` for that appearance. Importantly, it also explicitly says it has **no evidence** that government or commercial firewalls detect Hysteria from missing TCP HTTP/HTTPS; this is an optional extra-mile measure, not an evidence-backed requirement. [Full Server Config — HTTP/HTTPS masquerading](https://hysteria.network/docs/advanced/Full-Server-Config/#httphttps-masquerading)
   - **Inference:** a real, stable site or legitimate reverse proxy is stronger probe-facing camouflage than a constant string or default 404. It still does not conceal IP reputation, traffic timing/volume, or an operator capable of recognizing the authenticated Hysteria request.

3. **QUIC port, ALPN, and handshake fingerprinting.** Upstream defaults `listen` to UDP `:443`, described as the default HTTP/3 port. It also supports Linux-only port ranges/port hopping by installing nftables/iptables redirect rules. [Full Server Config — Listen](https://hysteria.network/docs/advanced/Full-Server-Config/#listen)
   - **Inference:** UDP/443 is the least unusual normal-HTTP/3 port choice. Port hopping may help with port-specific filtering but changes the port observable and is not documented as a general DPI-evasion guarantee. The pre-hardening repo exposed UDP/36712 on buyan and on the veles relay, a **medium-severity detectability risk** because it was nonstandard for normal HTTP/3. The Veles phase-1 change removes that port and moves the public ingress to UDP/443. This is not proof it was blocked or detected.
   - The current upstream documentation does not expose a server-side arbitrary ALPN/fingerprint setting. The protocol is HTTP/3 over QUIC; upstream's Chrome QUIC fingerprint parroting is a **client** setting, enabled by default. Its release notes say it makes the client handshake look like Chrome; the client docs warn that Chrome does not advertise Ed25519 signatures, so a parroted client needs an ECDSA or RSA server certificate (ACME certificates are unaffected). [v2.12.0 release](https://github.com/apernet/hysteria/releases/tag/app/v2.12.0) · [Full Client Config — QUIC](https://hysteria.network/docs/advanced/Full-Client-Config/#quic-parameters)
   - **Inference:** do not invent ALPN toggles at the server. Verify the actual Xray client/server ALPN and certificate algorithm with the deployed versions before depending on the upstream Chrome-parroting claim.

4. **Obfuscation versus HTTP/3.** By default Hysteria mimics HTTP/3. Upstream positions Salamander or experimental Gecko for cases where QUIC/HTTP/3 is blocked but UDP is allowed. Salamander makes packets seemingly random; Gecko adds randomized-size/padded fragmentation for QUIC handshake datagrams. Both ends require the same password. [Full Server Config — Obfuscation](https://hysteria.network/docs/advanced/Full-Server-Config/#obfuscation) · [Protocol — Salamander/Gecko](https://hysteria.network/docs/developers/Protocol/#salamander-obfuscation)
   - The project explicitly warns that enabling obfuscation makes the server incompatible with standard QUIC and no longer a valid HTTP/3 server. Gecko is explicitly experimental. [Full Server Config — Obfuscation](https://hysteria.network/docs/advanced/Full-Server-Config/#obfuscation)
   - **Inference:** use normal H3 + functioning masquerade where QUIC is viable; reserve obfuscation for measured QUIC/H3 blocking. Random-looking UDP may evade an HTTP/3 classifier but can be easier to block under a UDP allowlist. Do not claim both outcomes simultaneously.

5. **Bandwidth and traffic shape.** Server `bandwidth` values are per-client limits only when Brutal is selected. Brutal is fixed-rate, does not back off for loss/RTT, may compensate for loss by sending faster, and the project warns not to set bandwidth above the actual maximum because that produces slow/unstable service and wasted data. `disableLossCompensation` can force exact configured upload speed. `ignoreClientBandwidth: true` instead selects non-Brutal congestion control (default BBR) and makes server bandwidth limits ineffective for BBR/Reno. [Full Server Config — Bandwidth and congestion](https://hysteria.network/docs/advanced/Full-Server-Config/#bandwidth)
   - **Inference:** accurately cap Brutal below measured path capacity if it is required; otherwise prefer BBR/non-Brutal behavior for less aggressive loss-driven traffic. This is performance/fairness guidance, **not** a documented DPI-evasion feature.

## Repository review findings (pre-hardening review)

| Severity | Location | Finding | Evidence / consequence |
|---|---|---|---|
| High (conditional) | `machines/buyan/default.nix`; `machines/veles/default.nix` | Configured camouflage SNI values are unrelated third-party names; certificate SANs are secret/unavailable. | TLS/SNI consistency cannot be demonstrated. A mismatch breaks normal validation and is inconsistent with normal HTTPS. Verify SAN, SNI, certificate chain, and client validation before deployment. |
| High | `roles/network/xray/hysteria.nix` | The implementation is Xray's Hysteria2 inbound, not upstream `hysteria`; its config schema has no upstream `obfs`, `ech`, `sniGuard`, bandwidth, or TCP HTTP/HTTPS masquerade mappings. | Upstream feature statements are useful protocol guidance but are not proof that this deployment supports/configures them. Do not paste upstream YAML into this module. |
| Medium | `machines/buyan/default.nix:78`; `machines/veles/default.nix:89` | UDP port 36712 is nonstandard for ordinary HTTP/3. | Upstream default is 443; custom-port H3 is a possible classifier signal. This is an operational inference, not a project claim of detection. |
| Medium | `roles/network/xray/hysteria.nix:64-67, 111-114` | Masquerade defaults to an empty object, and upstream says absent masquerade returns 404; enabled host configs do not set it. | A default/constant probe response is contrary to upstream's advice to provide authentic content or reverse proxying. Confirm Xray's exact behavior separately. |

## Limits / residual risks

- No upstream source says Hysteria is immune to DPI, active probing, traffic analysis, IP reputation, or UDP-wide blocking. The strongest project language is that HTTP/3 masquerading makes blocking *difficult* without collateral damage, not impossible. [Upstream README](https://github.com/apernet/hysteria)
- This review did not inspect decrypted certificates, run an external HTTP/3/QUIC probe, capture packets, or test from a censored network. Those tests are required to validate the inferences.
- ECH and Chrome parroting are client/deployment-version dependent; neither is confirmed for this Xray-based configuration.

## Sources

### Kept
The Veles phase-1 configuration moves the Hysteria2 ingress to UDP/443 and
adds reverse-proxy masquerade. It improves the endpoint's unauthenticated
HTTP/3 response over the earlier default-404 configuration, but a self-signed
certificate pinned by clients while claiming a third-party SNI remains
observable to active probes and is not equivalent to publicly trusted HTTPS.

- [Hysteria Full Server Config](https://hysteria.network/docs/advanced/Full-Server-Config/) — first-party definitions and explicit caveats for TLS, port, obfs, bandwidth, and masquerade.
- [Hysteria Protocol](https://hysteria.network/docs/developers/Protocol/) — upstream protocol requirements for HTTP/3 behavior, active-probe failure handling, padding, and obfuscation wire behavior.
- [Hysteria ECH](https://hysteria.network/docs/advanced/ECH/) — first-party scope and failure behavior for ECH.
- [Hysteria Full Client Config](https://hysteria.network/docs/advanced/Full-Client-Config/#quic-parameters) and [v2.12.0 release](https://github.com/apernet/hysteria/releases/tag/app/v2.12.0) — upstream client-side Chrome fingerprint-parroting behavior.
- [Hysteria upstream README](https://github.com/apernet/hysteria) — project-level, deliberately limited censorship-resistance claim.

### Dropped
- Community discussions/issues and third-party configuration guides — excluded because the task requires first-party Hysteria documentation and upstream source/release documentation only.
- Xray documentation — intentionally excluded from the source set; it is needed before implementation changes but outside this research constraint.
