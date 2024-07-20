# Configuration for Virtual Machine

{ config, pkgs, lib, ... }:

{
  boot = {
    supportedFilesystems = [ "ext4" ];
    loader.grub.device = "/dev/sda1";
  };
}