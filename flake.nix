{
  description = "calendar's NixOS configurations";

  inputs = {
    # Pin an immutable nixpkgs commit from nixos-unstable. GitHub commit URLs
    # do not move, so the lock file stays reproducible and fetchable. This is
    # the nixos-unstable revision published on 2026-10-27:
    #   31ecbaca1bdefa45dffc409f0250bd8039ea0010
    #
    # To upgrade, change the commit below and run
    # `nix flake update nixpkgs`, then build and verify. Do not edit
    # flake.lock's narHash by hand or update unrelated inputs at the same time.
    nixpkgs.url = "github:NixOS/nixpkgs/31ecbaca1bdefa45dffc409f0250bd8039ea0010";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lazyvim-nix = {
      url = "github:pfassina/lazyvim-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      sops-nix,
      lazyvim-nix,
      ...
    }:
    let
      lib = nixpkgs.lib;

      mkHost =
        host: extraModules:
        lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            host
            sops-nix.nixosModules.sops
            home-manager.nixosModules.home-manager
          ] ++ extraModules;
        };

    in
    {
      nixosConfigurations = {
        # LazyVim is a main-only addition. The extra module is appended after
        # hosts/main, so the existing Home Manager user configuration keeps
        # applying and only imports one more user module.
        main = mkHost ./hosts/main [
          {
            home-manager.sharedModules = [
              lazyvim-nix.homeManagerModules.default
            ];

            home-manager.users.calendar.imports = [
              ./home/calendar/lazyvim.nix
            ];
          }
        ];

        nixos = mkHost ./hosts/nixos [ ];
      };
    };
}
