{ lib }:
let
  fail = message: throw "dns: ${message}";

  require = condition: message: if condition then true else fail message;

  nonEmptyString = value: builtins.isString value && value != "";

  requiredString =
    record: field:
    if builtins.hasAttr field record && nonEmptyString record.${field} then
      record.${field}
    else
      fail "record field `${field}` must be a non-empty string";

  absoluteTarget =
    record: field:
    let
      value = requiredString record field;
    in
    if lib.hasSuffix "." value then
      value
    else
      fail "record field `${field}` must be an absolute DNS name ending in `.`";

  renderTtl =
    ttl:
    if ttl == "auto" then
      1
    else if builtins.isInt ttl && ttl >= 60 then
      ttl
    else
      fail "ttl must be `auto` or an integer of at least 60";

  allowedFields = {
    A = [
      "type"
      "name"
      "address"
      "proxied"
      "ttl"
    ];
    CNAME = [
      "type"
      "name"
      "target"
      "proxied"
      "ttl"
    ];
    ALIAS = [
      "type"
      "name"
      "target"
      "proxied"
      "ttl"
    ];
    MX = [
      "type"
      "name"
      "priority"
      "exchange"
      "ttl"
    ];
    TXT = [
      "type"
      "name"
      "text"
      "ttl"
    ];
  };

  renderRecord =
    record:
    assert require (builtins.isAttrs record) "each record must be an attrset";
    assert require (record ? type && builtins.isString record.type) "each record needs string `type`";
    assert require (lib.elem record.type [
      "A"
      "CNAME"
      "ALIAS"
      "MX"
      "TXT"
    ]) "unsupported record type `${record.type}`";
    assert require (lib.all (field: lib.elem field allowedFields.${record.type}) (
      builtins.attrNames record
    )) "record type `${record.type}` has an unsupported field";
    assert require (
      record ? name && nonEmptyString record.name && !lib.hasSuffix "." record.name
    ) "record `name` must be a non-empty relative name";
    let
      ttl = renderTtl (record.ttl or "auto");
      proxyMeta =
        if record ? proxied then
          if
            lib.elem record.type [
              "A"
              "CNAME"
              "ALIAS"
            ]
            && builtins.isBool record.proxied
          then
            {
              cloudflare_proxy = if record.proxied then "on" else "off";
            }
          else
            fail "`proxied` is a boolean allowed only on A, ALIAS, and CNAME records"
        else
          { };
      common = {
        type = record.type;
        name = record.name;
        inherit ttl;
      }
      // lib.optionalAttrs (proxyMeta != { }) {
        meta = proxyMeta;
      };
    in
    if record.type == "A" then
      common
      // {
        target = requiredString record "address";
      }
    else if
      lib.elem record.type [
        "ALIAS"
        "CNAME"
      ]
    then
      common
      // {
        target = absoluteTarget record "target";
      }
    else if record.type == "MX" then
      assert require (
        record ? priority
        && builtins.isInt record.priority
        && record.priority >= 0
        && record.priority <= 65535
      ) "MX `priority` must be an integer from 0 through 65535";
      common
      // {
        target = absoluteTarget record "exchange";
        mxpreference = record.priority;
      }
    else
      common
      // {
        target =
          if record ? text && builtins.isString record.text then
            record.text
          else
            fail "TXT record field `text` must be a string";
      };

  renderZone =
    zone: spec:
    assert require (
      builtins.isString zone && zone != "" && !lib.hasSuffix "." zone
    ) "zone names must be non-empty and have no trailing dot";
    assert require (
      builtins.isAttrs spec && spec ? records && builtins.isList spec.records
    ) "zone `${zone}` needs a list of `records`";
    let
      records = map renderRecord spec.records;
      recordKeys = map builtins.toJSON records;
    in
    assert require (
      builtins.length recordKeys == builtins.length (lib.unique recordKeys)
    ) "zone `${zone}` contains an identical duplicate record";
    {
      name = zone;
      uniquename = zone;
      registrar = "none";
      dnsProviders = {
        cloudflare = 0;
      };
      inherit records;
    };
in
{
  render =
    zones:
    assert require (builtins.isAttrs zones) "zones must be an attrset";
    {
      registrars = [
        {
          name = "none";
          type = "NONE";
        }
      ];
      dns_providers = [
        {
          name = "cloudflare";
          type = "CLOUDFLAREAPI";
        }
      ];
      domains = map (zone: renderZone zone zones.${zone}) (
        lib.sort lib.lessThan (builtins.attrNames zones)
      );
    };
}
