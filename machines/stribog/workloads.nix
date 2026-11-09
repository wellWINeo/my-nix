{ ... }:
{
  imports = [
    ../../common/tailscale-client.nix
    ../../roles
    ../../roles/network/xray/profiles/reverse-relay.nix
  ];

  roles.hardened.enable = true;
  roles.observability.agent.enable = true;
}
