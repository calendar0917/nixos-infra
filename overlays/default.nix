{ ... }: {
  nixpkgs.overlays = [
    (final: prev: {
      maple-mono = final.callPackage ../pkgs/maple-mono.nix {};
    })
  ];
}
