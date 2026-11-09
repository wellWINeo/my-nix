let
  facts = {
    ifname = "eth0";
  };
in
{
  imports = [
    (import ./configuration.nix facts)
    (import ./workloads.nix facts)
  ];
}
