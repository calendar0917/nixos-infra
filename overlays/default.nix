{ ... }: {
  nixpkgs.overlays = [
    (final: prev: {
      cc-switch-cli = final.callPackage ../pkgs/cc-switch-cli.nix {};
      maple-mono = final.callPackage ../pkgs/maple-mono.nix {};
    })
  ];
}
