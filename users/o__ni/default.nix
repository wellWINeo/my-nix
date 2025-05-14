{ pkgs, ... }:

let
  secrets = import ../../secrets;
in
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
    ];
    packages = with pkgs; [
      git
      gnupg
      gnumake
      neofetch
      neovim
      htop
    ];

    hashedPassword = secrets.hashedPassword;
    openssh.authorizedKeys.keys = [ secrets.sshKey ];
  };
}
