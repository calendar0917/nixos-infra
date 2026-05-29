{
  description = "NixOS configuration";

  inputs = {
    nixpkgs.url = "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/nixos-unstable/nixexprs.tar.xz";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, ... } @ inputs: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        # Overlay: 注入自定义包（必须在 HM 之前）
        ({ pkgs, ... }: {
          nixpkgs.overlays = [
            (final: prev: {
              cc-switch-cli = final.callPackage ./pkgs/cc-switch-cli.nix {};
            })
          ];
        })

        ./hosts/nixos
        home-manager.nixosModules.home-manager
      ];
    };
  };
}
