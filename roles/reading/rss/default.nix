{ ... }:

{
  imports = [
    ./miniflux.nix
    ./summarizer/service.nix
    ./backup.nix
  ];
}
