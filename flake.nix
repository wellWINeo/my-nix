{
  description = "o__ni's nix flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };

  outputs = { self, nixpkgs, ... }@inputs: {

    # raspberry pi 4
    nixosConfigurations."nixpi" = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = inputs;
      modules = [
        ./machines/nixpi
        ./users/o__ni
      ];
    };

    # VPS 1 CPU, 2GB RAM
    nixosConfigurations."mokosh" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = inputs;
      modules = [
        ./machines/mokosh
        ./users/o__ni
      ];
    };
  };
}
