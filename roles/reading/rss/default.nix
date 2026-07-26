{ ... }:

{
  imports = [
    ./miniflux.nix
    ./rsshub.nix
    ./summarizer/service.nix
    ./backup.nix
  ];
}
