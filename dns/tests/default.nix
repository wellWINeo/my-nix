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
      and [.domains[0].records[].type] == ["A", "CNAME", "MX", "TXT"]
      and .domains[0].records[0].meta.cloudflare_proxy == "on"
      and .domains[0].records[1].meta.cloudflare_proxy == "off"
      and .domains[0].records[2].mxpreference == 10
      and .domains[0].records[3].target == "v=spf1 -all"
    ' ${ir} >/dev/null

    touch "$out"
  ''
