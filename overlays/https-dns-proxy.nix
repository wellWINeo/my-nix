{ config, pkgs, ... }:

self: super:

{
  https-dns-proxy = super.https-dns-proxy.overrideAttrs (old: rec {
    src = pkgs.fetchFromGithub {
      owner = "aarond10";
      repo = "https_dns_proxy";
      rev = "8afbba71502ddd5aee91602318875a03e86dfc4e";
      hash = "sha256-sJlSIwx93Npu2qUwcWW13etGSTcOAPbj1uBb+wn4cYA=";
    };
  });
}