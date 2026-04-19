{ config, lib, pkgs, ... }:

{
  imports = [
    ./miniflux.nix
    ./summarizer/service.nix
  ];
}
