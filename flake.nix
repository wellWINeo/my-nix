{
  description = "o__ni's nix flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    miniflux-summarizer.url = "github:wellWINeo/miniflux-summarizer";
  };

  outputs =
    { nixpkgs, nixpkgs-unstable, ... }@inputs:
    let
      supportedSystems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      overlays = import ./overlays/default.nix;
      nixpkgsFor = forAllSystems (
        system:
        import nixpkgs {
          inherit system overlays;
          config.allowUnfree = true;
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
          {
            nixpkgs.overlays = (import ./overlays) ++ [
              (final: prev: {
                miniflux-summarizer =
                  inputs.miniflux-summarizer.packages.${prev.stdenv.hostPlatform.system}.default;
              })
            ];
          }
          ./machines/mokosh
          ./users/o__ni
        ];
      };

      # VPS 1 CPU, 1GB RAM (RU)
      nixosConfigurations."veles" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = inputs;
        modules = [
          {
            nixpkgs.overlays = (import ./overlays) ++ [
              (final: prev: {
                telemt = nixpkgs-unstable.legacyPackages.${prev.stdenv.hostPlatform.system}.telemt;
              })
            ];
          }
          ./machines/veles
          ./users/o__ni
        ];
      };

      # VPS 1 CPU, 1GB RAM (NL)
      nixosConfigurations."buyan" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = inputs;
        modules = [
          ./machines/buyan
          ./users/o__ni
        ];
      };

      # standalone home-manager for macOS
      homeConfigurations."o__ni@Stepans-MacBook-Pro" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgsFor.aarch64-darwin;
        modules = [
          ./home
          {
            software.alacritty.enable = true;
            software.alacritty.theme = "one-dark";
          }
        ];
      };

      homeConfigurations."o__ni@DodoBook.local" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgsFor.aarch64-darwin;
        modules = [
          ./home
          {
            software.alacritty.enable = true;
            software.alacritty.theme = "one-half-light";
          }
        ];
      };

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
