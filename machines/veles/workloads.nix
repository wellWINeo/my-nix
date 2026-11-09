{ ... }:
{
  imports = [
    ../../common/tailscale-client.nix
    ../../roles
    ../../roles/network/xray/profiles/reverse-relay.nix
  ];

  roles.hardened.enable = true;
  roles.observability.agent.enable = true;

  # CDN-fronted loopback ingress (Timeweb edge -> HTTPS origin -> Nginx
  # -> 127.0.0.1:9013). Decryption is injected at runtime from the
  # human-installed credential file, and the guarded startup fails closed
  # until the operator installs a valid value. Activating this CDN path is a
  # separately approved deployment gate with its own go/no-go tests
  # (docs/veles-timeweb-cdn-deployment.md); building or merging this
  # configuration never deploys it.
  roles.xray.relay.ingress.vless.cdnXhttp = {
    enable = true;
    originDomain = "sunny-bee-on-the-flower.net.by";
    path = "/vl-cdn";
    decryptionFile = "/etc/nixos/secrets/vlessenc-decryption-key";
  };

  # Keep Veles's explicit disabled Hysteria2 forward target unchanged.
  roles.xray.relay.egress.forward.hysteria2 = {
    enable = false;
    serverName = "bing.com";
    insecure = true;
    certificateFingerprint = null;
    port = 36712;
  };
}
