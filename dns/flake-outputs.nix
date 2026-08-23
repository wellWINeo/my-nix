{ forAllSystems, nixpkgsFor }:
let
  dnsFor =
    system:
    let
      pkgs = nixpkgsFor.${system};
      dns = import ./default.nix { inherit pkgs; };
      apps = import ./apps.nix {
        inherit pkgs;
        ir = dns.ir;
      };
    in
    {
      inherit apps dns;
    };
in
{
  checks = forAllSystems (
    system:
    let
      pkgs = nixpkgsFor.${system};
      apps = (dnsFor system).apps;
      dns = (dnsFor system).dns;
    in
    {
      dns-render = import ./tests { inherit pkgs; };
      dns-app-safety = import ./tests/apps.nix { inherit pkgs apps; };
      dns-config =
        pkgs.runCommand "dns-config-check"
          {
            nativeBuildInputs = [ pkgs.dnscontrol ];
          }
          ''
            set -euo pipefail
            dnscontrol check --ir ${dns.ir} | tee "$TMPDIR/dnscontrol-check.out"
            grep -Fx 'No errors.' "$TMPDIR/dnscontrol-check.out"
            touch "$out"
          '';
    }
  );

  apps = forAllSystems (
    system:
    let
      dnsApps = (dnsFor system).apps;
    in
    {
      dns-preview = {
        type = "app";
        program = "${dnsApps.preview}/bin/dns-preview";
      };
      dns-drift-check = {
        type = "app";
        program = "${dnsApps.driftCheck}/bin/dns-drift-check";
      };
      dns-apply = {
        type = "app";
        program = "${dnsApps.apply}/bin/dns-apply";
      };
    }
  );

  packages = forAllSystems (
    system:
    let
      dns = dnsFor system;
    in
    {
      dnscontrol-ir = dns.dns.ir;
      dns-preview = dns.apps.preview;
      dns-drift-check = dns.apps.driftCheck;
      dns-apply = dns.apps.apply;
    }
  );
}
