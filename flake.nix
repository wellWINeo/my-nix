{
  description = "o__ni's nix flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };

  outputs =
    { nixpkgs, ... }@inputs:
    let
      supportedSystems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      overlay = final: prev: {
        miniflux-ai = final.callPackage ./pkgs/miniflux-ai.nix { };
      };

      nixpkgsFor = forAllSystems (
        system:
        import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        }
      );
    in
    {

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

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          miniflux-ai = pkgs.miniflux-ai;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              nixfmt-rfc-style
              nixd
            ];
          };
        }
      );
    };
}
