# roles/network/xray/vless.nix
#
# Pure builders for VLESS config fragments shared by the xray role modes:
# REALITY server inbounds, regular (vnext) outbounds, and the structurally
# different simplified reverse outbound. These helpers never read machine
# config or secrets; callers construct the transport-specific REALITY client
# streamSettings and pass UUIDs explicitly.
{ lib }:

let
  # Server-side REALITY realitySettings block. privateKey is injected at
  # runtime by the coordinator, so it stays out of these builders.
  mkRealityServerSettings =
    { sni, shortIds }:
    {
      target = "${sni}:443";
      serverNames = [ sni ];
      shortIds = shortIds;
    };

  # User entry shared by the outbound shapes. `flow` is only emitted when
  # non-null (e.g. xtls-rprx-vision for TCP+Vision).
  mkOutboundUser =
    { uuid, flow }:
    {
      id = uuid;
      encryption = "none";
    }
    // lib.optionalAttrs (flow != null) { inherit flow; };
in
{
  # Pure ClientHello-fragment helper for eventual call sites (Buyan bridge,
  # forward targets). Fragments only outgoing ClientHello messages.
  withClientHelloFragmentation =
    outbound:
    lib.recursiveUpdate outbound {
      streamSettings.finalmask.tcp = [
        {
          type = "fragment";
          settings = {
            packets = "tlshello";
            lengths = [ "100-200" ];
            delays = [ "10-20" ];
            maxSplit = "3-6";
          };
        }
      ];
    };

  # VLESS REALITY inbound. `transport` selects the network and the
  # transport-specific streamSettings fields: "raw" -> tcp (no extra block),
  # "grpc" -> grpc with ALPN h2 + serviceName, "xhttp" -> xhttp + path.
  mkInbound =
    {
      transport,
      tag,
      port,
      clients,
      sni,
      shortIds,
      path ? "/vl-xhttp",
      serviceName ? "VlGrpc",
    }:
    {
      listen = "127.0.0.1";
      inherit tag port;
      protocol = "vless";
      settings = {
        inherit clients;
        decryption = "none";
      };
      streamSettings = {
        network =
          {
            raw = "tcp";
            grpc = "grpc";
            xhttp = "xhttp";
          }
          .${transport};
        security = "reality";
        realitySettings =
          mkRealityServerSettings { inherit sni shortIds; }
          // lib.optionalAttrs (transport == "grpc") { alpn = [ "h2" ]; };
        sockopt.acceptProxyProtocol = true;
      }
      // lib.optionalAttrs (transport == "grpc") {
        grpcSettings.serviceName = serviceName;
      }
      // lib.optionalAttrs (transport == "xhttp") {
        xhttpSettings.path = path;
      };
    };

  # Regular VLESS outbound using the classic vnext[].users[] shape.
  mkRegularOutbound =
    {
      tag,
      address,
      port,
      uuid,
      streamSettings,
      flow ? null,
    }:
    {
      protocol = "vless";
      inherit tag streamSettings;
      settings = {
        vnext = [
          {
            inherit address port;
            users = [ (mkOutboundUser { inherit uuid flow; }) ];
          }
        ];
      };
    };

  # Simplified reverse outbound: Xray's VLESS parser rejects `reverse` inside
  # the vnext[].users[] shape, so the reverse link must use the simplified
  # settings-level shape (address/port/id/encryption plus reverse.tag naming
  # the logical inbound tag) and never `vnext`.
  mkReverseOutbound =
    {
      tag,
      address,
      port,
      uuid,
      inboundTag,
      streamSettings,
      flow ? null,
    }:
    {
      protocol = "vless";
      inherit tag streamSettings;
      settings = {
        inherit address port;
        id = uuid;
        encryption = "none";
        reverse.tag = inboundTag;
      }
      // lib.optionalAttrs (flow != null) { inherit flow; };
    };
}
