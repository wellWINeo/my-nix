{
  description = "o__ni's nix flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    miniflux-summarizer = {
      url = "github:wellWINeo/miniflux-summarizer";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agent-skills = {
      url = "github:Kyure-A/agent-skills-nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    superpowers = {
      url = "github:obra/superpowers";
      flake = false;
    };
    dotnet-skills = {
      url = "github:dotnet/skills";
      flake = false;
    };
    mattpocock-skills = {
      url = "github:mattpocock/skills";
      flake = false;
    };
    ponytail-skills = {
      url = "github:dietrichgebert/ponytail";
      flake = false;
    };
    gh-stack-skill = {
      url = "github:github/gh-stack";
      flake = false;
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
      dnsFor =
        system:
        let
          pkgs = nixpkgsFor.${system};
          dns = import ./dns { inherit pkgs; };
          apps = import ./dns/apps.nix {
            inherit pkgs;
            ir = dns.ir;
          };
        in
        {
          inherit apps dns;
        };
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
            codingAgents = {
              claude.enable = true;
              opencode.enable = true;
              codex.enable = true;
            };
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

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
          dns = import ./dns { inherit pkgs; };
        in
        {
          dns-render = import ./dns/tests { inherit pkgs; };
          dns-config =
            pkgs.runCommand "dns-config-check"
              {
                nativeBuildInputs = [ pkgs.dnscontrol ];
              }
              ''
                set -euo pipefail
                dnscontrol check --ir ${dns.ir} | tee "$TMPDIR/dnscontrol-check.out"
                grep -Fx 'No errors.' "$TMPDIR/dnscontrol-check.out"
                touch "$out"
              '';
        }
      );

      apps = forAllSystems (
        system:
        let
          dnsApps = (dnsFor system).apps;
        in
        {
          dns-preview = {
            type = "app";
            program = "${dnsApps.preview}/bin/dns-preview";
          };
          dns-drift-check = {
            type = "app";
            program = "${dnsApps.driftCheck}/bin/dns-drift-check";
          };
          dns-apply = {
            type = "app";
            program = "${dnsApps.apply}/bin/dns-apply";
          };
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
          dnscontrol-ir = (dnsFor system).dns.ir;
          dns-preview = (dnsFor system).apps.preview;
          dns-drift-check = (dnsFor system).apps.driftCheck;
          dns-apply = (dnsFor system).apps.apply;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          do-image = self.nixosConfigurations."do-generic".config.system.build.digitalOceanImage;
        }
      );
    };
}
