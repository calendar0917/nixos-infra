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

    flakida = {
      url = "github:LyCecilion/flakida-9.4/5e69153b0d60ac7932a2aec53739476c5b9c0db7";
    };

    burpPro = {
      url = "github:KIRAN-KUMAR-K3/BurpPro-Installer/7627e854d555889bc361b3ed81db48ca5ff49814";
    };

    pwndbg = {
      url = "github:pwndbg/pwndbg/9760ac8f1346d142857cffc933995cd6fca34dff";
    };
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      sops-nix,
      lazyvim-nix,
      burpPro,
      flakida,
      pwndbg,
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
        # LazyVim and the security lab are main-only additions. The extra
        # module is appended after hosts/main, so the existing Home Manager
        # user configuration keeps applying and only imports the extra user
        # modules.
        main = mkHost ./hosts/main [
          (
            { ... }:
            {
              home-manager.extraSpecialArgs = {
                inherit burpPro flakida pwndbg;
              };

              home-manager.sharedModules = [
                lazyvim-nix.homeManagerModules.default
              ];

              home-manager.users.calendar.imports = [
                ./home/calendar/lazyvim.nix
                ./home/calendar/security-lab.nix
              ];
            }
          )
        ];

        nixos = mkHost ./hosts/nixos [ ];
      };
    };
}
