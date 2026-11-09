{
  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = "/etc/nixos/secrets/tailscale-auth-key";
    extraUpFlags = [
      "--login-server=https://headscale.uspenskiy.tech"
      "--accept-dns=false"
    ];
    extraSetFlags = [ "--accept-dns=false" ];
  };

  systemd.services.tailscaled-autoconnect.serviceConfig = {
    Restart = "on-failure";
    RestartSec = "30s";
  };
}
