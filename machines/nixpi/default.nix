let
  facts = {
    ifname = "end0";
    ip = "192.168.0.20";
    gatewayIP = "192.168.0.1";
  };
in
{
  imports = [
    (import ./configuration.nix facts)
    (import ./workloads.nix facts)
  ];
}
