{
  description = "calendar's single-host NixOS configuration";

  inputs = {
    # nixpkgs is pinned to an immutable channel tarball built from the exact
    # revision this machine was deployed from:
    #   02c087f3fe673c9e317f206a627cb6b910336dbe
    #   nixos-unstable, channel version pre1097682.02c087f3fe67
    # The previous URL was the rolling TUNA nixos-unstable channel: its content
    # changes while the URL stays the same, so the lock file's narHash goes
    # stale and a fresh fetch fails. releases.nixos.org keeps this versioned
    # tarball, so the locked content stays fetchable. The narHash in
    # flake.lock was verified against this exact URL with
    # `nix store prefetch-file --unpack`.
    #
    # Do not bump this by hand. To upgrade, switch the URL to a newer release
    # tarball and run `nix flake lock --update-input nixpkgs`, then rebuild and
    # verify; see README for the procedure. Changing only the URL leaves the
    # old narHash in place and the fetch will fail.
    nixpkgs.url = "https://releases.nixos.org/nixos/unstable/nixos-26.11pre1097682.02c087f3fe67/nixexprs.tar.xz";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, sops-nix, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/nixos
        sops-nix.nixosModules.sops
        home-manager.nixosModules.home-manager
      ];
    };
  };
}
