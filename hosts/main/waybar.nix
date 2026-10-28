{ pkgs, ... }:

# main needs Waybar's workspace-taskbar, which is not in the 0.15.0 release
# pinned by this nixpkgs. Pin one upstream development commit and build it
# against the already-locked nixpkgs libraries. Do not follow master and do
# not update the rest of nixpkgs for this.
#
# The codeload URL is used instead of fetchFromGitHub because github.com's
# /archive redirect is unreliable on this network; the content is fixed by
# the hash and the commit below.
{
  nixpkgs.overlays = [
    (final: prev: {
      waybar = (prev.waybar.override { cavaSupport = false; }).overrideAttrs (old: rec {
        version = "0.15.0-unstable-2026-10-19";

        src = prev.fetchzip {
          name = "Waybar-c15ec02";
          extension = "tar.gz";
          url = "https://codeload.github.com/Alexays/Waybar/tar.gz/c15ec02ede4343592a59eb5c2ff4443c9c045f7c";
          hash = "sha256-mBDWjeeIuFfDZQuBxHu+EpbJ+GMbbSxpRz0WVM2N+ZI=";
        };

        # This revision gained explicit fmt and xkbregistry dependencies.
        # xkbregistry is already provided by libxkbcommon in buildInputs.
        buildInputs = old.buildInputs ++ [ final.fmt ];

        # The wwan option is new and would require ModemManager. This host uses
        # NetworkManager, not WWAN, so keep the existing feature set.
        mesonFlags = old.mesonFlags ++ [ "-Dwwan=disabled" ];

        # Keep the package version and the binary's reported version in sync
        # for versionCheckHook. The upstream source still says 0.15.0.
        postPatch = (old.postPatch or "") + ''
          substituteInPlace meson.build \
            --replace-fail "version: '0.15.0'" "version: '${version}'"
        '';
      });
    })
  ];
}
