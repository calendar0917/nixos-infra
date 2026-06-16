{
  description = "NixOS configuration";
  inputs = {
    nixpkgs.url = "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/nixos-unstable/nixexprs.tar.xz";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, sops-nix, ... } @ inputs: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
              {
          nix.settings = {
            substituters = [
              "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
              "https://cache.nixos.org"
            ];
            trusted-substituters = [
              "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
            ];
            trusted-public-keys = [
              "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
              "tuna.tsinghua.edu.cn-1:Dk5GQyD1H6hLm1W7q1Z6Tp8J9nK7yR4vF2X3E5B7N1M="
            ];
          };
        }
         # Overlay: # 注入自定义包（必须在 HM 之前）
        ({ pkgs, ... }: {
          nixpkgs.overlays = [
            (final: prev: {
              cc-switch-cli = final.callPackage ./pkgs/cc-switch-cli.nix {};
            })
          ];
        })

        ./hosts/nixos
        sops-nix.nixosModules.sops
        home-manager.nixosModules.home-manager
      ];
    };
  };
}
