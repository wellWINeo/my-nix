{ lib, ... }:

let
  hostname = "stribog";
  ifname = "net0";
  secrets = import ../../secrets;
  ip = secrets.ip.stribog;
in
{
  imports = [
    ../../common/cache.nix
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
  ];

  boot = {
    loader.grub.device = "/dev/vda";

    # IPv6 is disabled on this host, matching Veles's network configuration.
    kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;
  };
  boot.initrd.systemd.enable = false;
  fileSystems."/" = {
    device = "/dev/vda2";
    fsType = "ext4";
  };
  zramSwap.enable = true;

  networking = {
    hostName = hostname;
    useDHCP = false;
    dhcpcd.enable = false;
    usePredictableInterfaceNames = lib.mkForce true;
    nameservers = [ "1.1.1.1" ];
    firewall.enable = true;
    interfaces.${ifname} = {
      ipv4.addresses = [
        {
          address = ip.address;
          prefixLength = 32;
        }
      ];
      ipv4.routes = [
        {
          address = ip.gateway;
          prefixLength = 32;
        }
      ];
    };
    defaultGateway = {
      address = ip.gateway;
      interface = ifname;
    };
  };
  services.udev.extraRules = ''
    ATTR{address}=="${ip.macAddress}", NAME="${ifname}"
  '';

  services.openssh.settings = {
    PermitRootLogin = "prohibit-password";
    PasswordAuthentication = false;
  };
  users.users.root.openssh.authorizedKeys.keys = [ secrets.sshKey ];

  services.qemuGuest.enable = true;
  system.stateVersion = "23.11";
}
