{ lib, ... }:

{
  nix.settings = {
    substituters = lib.mkAfter [
      "https://storage.yandexcloud.net/nix-cache"
      "https://d3ktcuzmslp03i.cloudfront.net"
    ];
    trusted-public-keys = [
      "wellwineo-nix-cache:gOwCJq94aNwmmjxIHYy+w/WKmSywDYfgA4oiFVbUoMY="
      "nix-anysync-cache:8ig/2DyERXghDDOwhDJcjZaxx+A77HwREpQfSIh1oZc="
    ];
  };
}
