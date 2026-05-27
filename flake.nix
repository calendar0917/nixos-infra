{
  description = "NixOS config";
 
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    vicinae.url = "github:vicinaehq/vicinae";
    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-colors.url = "github:misterio77/nix-colors";
  };
 
  outputs = inputs@{ self, nixpkgs, home-manager, niri, vicinae, noctalia, nix-colors, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        ./configuration.nix
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.YOUR_USER = import ./home.nix;
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [
            niri.homeModules.niri
            vicinae.homeManagerModules.default
            noctalia.homeModules.default
            nix-colors.homeManagerModules.default
          ];
        }
      ];
    };
  };
}
