{
  description = "o__ni's nix flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    miniflux-summarizer.url = "github:wellWINeo/miniflux-summarizer";
    agent-skills = {
      url = "github:Kyure-A/agent-skills-nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    nixvim = {
      url = "github:nix-community/nixvim/nixos-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      ...
    }@inputs:
    let
      supportedSystems = [
        "x86_64-linux"
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

      # generic DigitalOcean image (any x86_64 droplet)
      nixosConfigurations."do-generic" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = inputs;
        modules = [
          ./common/cache.nix
          ./common/server.nix
          ./users/o__ni
          ./images/do-generic
          { system.stateVersion = "26.05"; }
        ];
      };

      # standalone home-manager for macOS
      homeConfigurations."o__ni@Stepans-MacBook-Pro" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgsFor.aarch64-darwin;
        extraSpecialArgs = { inherit inputs; };
        modules = [
          inputs.agent-skills.homeManagerModules.default
          inputs.nixvim.homeModules.nixvim
          ./home
          {
            software.alacritty.enable = true;
            theme.name = "one-dark";
            software.neovim.enable = true;
            codingAgents.claude.enable = true;
            codingAgents.opencode.enable = true;
          }
        ];
      };

      homeConfigurations."o__ni@DodoBook.local" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgsFor.aarch64-darwin;
        extraSpecialArgs = { inherit inputs; };
        modules = [
          inputs.agent-skills.homeManagerModules.default
          inputs.nixvim.homeModules.nixvim
          ./home
          {
            software.alacritty.enable = true;
            theme.name = "one-half-light";
            software.neovim.enable = true;
            codingAgents.claude.enable = true;
            codingAgents.opencode.enable = true;
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
              nixfmt
              nixd
            ];
          };
        }
      );

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          bulwark-webmail = pkgs.bulwark-webmail;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          do-image = self.nixosConfigurations."do-generic".config.system.build.digitalOceanImage;
        }
      );
    };
}
