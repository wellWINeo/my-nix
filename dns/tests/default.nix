{ pkgs }:
let
  renderer = import ../lib.nix { inherit (pkgs) lib; };
  config = renderer.render (import ./zones.nix);
  ir = pkgs.writeText "dnscontrol-render-test.json" (builtins.toJSON config);
  mustFail = zones: !(builtins.tryEval (builtins.deepSeq (renderer.render zones) true)).success;
  invalidCname = {
    "example.test".records = [
      {
        type = "CNAME";
        name = "www";
        target = "origin.example.net";
      }
    ];
  };
  invalidAlias = {
    "example.test".records = [
      {
        type = "ALIAS";
        name = "@";
        target = "pages.example.net";
      }
    ];
  };
  invalidMxProxy = {
    "example.test".records = [
      {
        type = "MX";
        name = "@";
        priority = 10;
        exchange = "mail.example.test.";
        proxied = true;
      }
    ];
  };
  invalidTxtAddress = {
    "example.test".records = [
      {
        type = "TXT";
        name = "@";
        text = "v=spf1 -all";
        address = "192.0.2.10";
      }
    ];
  };
  invalidType = {
    "example.test".records = [
      {
        type = "AAAA";
        name = "@";
        address = "2001:db8::10";
      }
    ];
  };
  validationCasesPass =
    assert mustFail invalidCname;
    assert mustFail invalidAlias;
    assert mustFail invalidMxProxy;
    assert mustFail invalidTxtAddress;
    assert mustFail invalidType;
    true;
in
assert validationCasesPass;
pkgs.runCommand "dns-render-test"
  {
    nativeBuildInputs = [
      pkgs.dnscontrol
      pkgs.jq
    ];
  }
  ''
    set -euo pipefail

    dnscontrol check --ir ${ir} | tee "$TMPDIR/dnscontrol-check.out"
    grep -Fx 'No errors.' "$TMPDIR/dnscontrol-check.out"

    jq -e '
      .registrars == [{"name": "none", "type": "NONE"}]
      and .dns_providers == [{"name": "cloudflare", "type": "CLOUDFLAREAPI"}]
      and .domains[0].name == "example.test"
      and [.domains[0].records[].type] == ["A", "CNAME", "ALIAS", "MX", "TXT"]
      and .domains[0].records[0].meta.cloudflare_proxy == "on"
      and .domains[0].records[1].meta.cloudflare_proxy == "off"
      and .domains[0].records[2].meta.cloudflare_proxy == "on"
      and .domains[0].records[3].mxpreference == 10
      and .domains[0].records[4].target == "v=spf1 -all"
      and .domains[0].records[0].target == "192.0.2.10"
      and .domains[0].records[0].ttl == 1
      and .domains[0].records[1].target == "origin.example.net."
      and .domains[0].records[1].ttl == 300
      and .domains[0].records[2].target == "pages.example.net."
      and .domains[0].records[2].ttl == 1
      and .domains[0].records[3].target == "mail.example.test."
      and .domains[0].records[3].ttl == 3600
      and .domains[0].records[4].ttl == 3600
    ' ${ir} >/dev/null

    touch "$out"
  ''
