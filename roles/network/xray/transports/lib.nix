# roles/network/xray/transports/lib.nix
#
# Shared helpers used by transport modules to build xray config fragments
# and vless:// subscription URIs. Keeping these here lets individual transport
# files stay focused on what is actually unique to each protocol.
{ lib }:

with lib;

rec {
  # Reality server-side realitySettings block. privateKey is injected at
  # runtime by the coordinator (see default.nix), so we leave it out here.
  mkRealityServerSettings =
    { sni, shortIds }:
    {
      target = "${sni}:443";
      serverNames = [ sni ];
      shortIds = shortIds;
    };

  # Reality client-side realitySettings block, used when connecting TO an
  # xray server (client or relay outbound). `reality` is an attrset with
  # publicKey/shortId/fingerprint and a fallback serverName.
  mkRealityClientSettings =
    { reality, serverName }:
    let
      sni = if serverName != "" then serverName else reality.serverName;
    in
    {
      publicKey = reality.publicKey;
      shortId = reality.shortId;
      serverName = sni;
      fingerprint = reality.fingerprint;
    };

  # Build a VLESS vnext outbound. `extraUser` is merged into the user entry
  # (used to add flow=xtls-rprx-vision for TCP+Vision).
  mkVnextOutbound =
    {
      tag,
      address,
      port,
      uuid,
      extraUser ? { },
      streamSettings,
    }:
    {
      protocol = "vless";
      tag = tag;
      settings = {
        vnext = [
          {
            address = address;
            port = port;
            users = [
              ({
                id = uuid;
                encryption = "none";
              } // extraUser)
            ];
          }
        ];
      };
      streamSettings = streamSettings;
    };

  # URL-encode a single string. Good enough for the characters that show up
  # in SNI, paths, gRPC service names, and fingerprints.
  urlEncode =
    str:
    let
      replace = pairs: s: foldl' (acc: p: builtins.replaceStrings [ (elemAt p 0) ] [ (elemAt p 1) ] acc) s pairs;
    in
    replace [
      [ "%" "%25" ]
      [ " " "%20" ]
      [ "/" "%2F" ]
      [ "?" "%3F" ]
      [ "#" "%23" ]
      [ "&" "%26" ]
      [ "=" "%3D" ]
    ] str;

  # Build a `vless://uuid@addr:port?k=v&...#tag` URI string from a params
  # attrset. Params are sorted for determinism.
  mkVlessUri =
    {
      uuid,
      addr,
      port ? 443,
      params,
      tag,
    }:
    let
      keys = lib.sort lessThan (lib.attrNames params);
      pairs = map (k: "${k}=${urlEncode (toString params.${k})}") keys;
      query = lib.concatStringsSep "&" pairs;
    in
    "vless://${uuid}@${addr}:${toString port}?${query}#${urlEncode tag}";
}
