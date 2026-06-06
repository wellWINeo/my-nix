{ pkgs, ... }:

{
  nix.settings.experimental-features = [
    "flakes"
    "nix-command"
  ];
  nixpkgs.config.allowUnfree = true;

  time.timeZone = "Europe/Moscow";

  i18n.defaultLocale = "en_US.UTF-8";

  users.users.o__ni = {
    isNormalUser = true;
    description = "Stepan Uspenskiy";
    extraGroups = [
      "users"
      "wheel"
      "media"
    ];
    packages = with pkgs; [
      git
      gnupg
      gnumake
      neofetch
      neovim
      htop
    ];

    hashedPassword = "$6$XcCZkywz$BKCmi6.12Oe5s17ixN8GFbRmfv2E1/SrLQO9FNnJ4gDJI5sxJGXSKNCEF8Msur3U9mbwCXj4aepkRWetMCYx3.";
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCnGEbhc1huuqNEF4PVgkdRqBWwB1SdG51Jt/XoHAA8gBc2h/SqKVwuumGT0tKZR4fhZ3Au2Iz3zTKrVj0bhqOiC3eDVK3rlWtn+Ts0QSx3LIUY474pmKITbeG5nyYEz1FjhpuanlUtnykSXRCmUaQGl1a4ULgyQf2l0cMriM0e4MVZmkf6i+rm9JC3/jz75WHQg2AJiJsV0ZNQeVim20Jufod1mg9K9Eqr8cdV09APvhgjs3/MiPqmqeDcLGTJgaNfEtOG+W2gjYVN0QFdB3ERy9C+r/55BQONZzIFwHjt/DvlWF+Ca6kuK0SkPk3VqV2C+NxCKrZrojLv7TmFn4kFhJbN/pHunJnFpLXdvmWPLAg1qZ5LKRrY83JKX4hPcWNuuEHeEe0V2RBa1E6V7dJtEOPdQYxv8lOyR0HeKvX4iQPy+PHj756URygxUWW0kP6Z46rwUeTsdaOSrlqRdrs7hvfi5BPImfx3nlBV2GXOwz7lIV0DXKm9BGTYrCxqw7GNLgZge0c0Cws4UzXkabDt1gXXWngxUr0heLNaMCe+u2SFVBnIEUvJ1QmljNBNGiLWZdqdgJtZrdNJX3GqJoE5W39+1lGnA0UDq28k+duFsXh+ojzGhb0BA3Sevc5d5W7BomZeg6t3rtnF+CvCf3uVCGlNwIM5XG33NRc7hO2WxQ== o__ni@Stepans-MacBook-Pro.local"
    ];
  };
}
