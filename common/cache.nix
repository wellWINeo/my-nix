{ lib, ... }:

{
  nix.settings = {
    substituters = lib.mkAfter [ "https://storage.yandexcloud.net/nix-cache" ];
    trusted-public-keys = [ "wellwineo-nix-cache:gOwCJq94aNwmmjxIHYy+w/WKmSywDYfgA4oiFVbUoMY=" ];
  };
}
