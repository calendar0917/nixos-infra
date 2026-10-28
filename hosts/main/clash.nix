{ pkgs, ... }:

let
  # Clash Verge Rev's Nixpkgs wrapper installs v2ray-domain-list-community's
  # geosite.dat. That dataset has no `gfw` list, while this subscription's DNS
  # fallback-filter references `geosite: [gfw]`. Pin MetaCubeX meta-rules-dat
  # by immutable release-branch commit, not by the rolling `latest` asset.
  #
  # The file is copied into the application's writable data directory below;
  # never make that path a read-only Nix symlink.
  geosite = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/f57214884b79e6e6770d753950b81242dd7f2541/geosite.dat";
    hash = "sha256-uolohHv7gqT5sMM9p3ttlfT4/h19O7JBp+usbCO3FjE=";
  };

  clashDataDir = "/home/calendar/.local/share/io.github.clash-verge-rev.clash-verge-rev";

  # Install after /home is mounted. Do not use an activation script here:
  # stage-2 activation can run before the separate /home filesystem is mounted,
  # which would write into the root filesystem.
  clashGeositeInstall = pkgs.writeShellScript "clash-geosite-install" ''
    set -eu
    umask 022
    ${pkgs.coreutils}/bin/install -d -m 0755 -o calendar -g calendar ${clashDataDir}
    tmp=${clashDataDir}/.geosite.dat.tmp
    ${pkgs.coreutils}/bin/rm -f "$tmp"
    ${pkgs.coreutils}/bin/install -m 0644 -o calendar -g calendar ${geosite} "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" ${clashDataDir}/geosite.dat
  '';
in
{
  systemd.services.clash-verge-geosite = {
    description = "Install pinned MetaCubeX geosite.dat for Clash Verge";
    wantedBy = [ "multi-user.target" ];
    before = [ "display-manager.service" ];
    unitConfig.RequiresMountsFor = "/home/calendar";

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = clashGeositeInstall;
    };
  };

  # No standalone Mihomo service is provided. Clash Verge is the only intended
  # owner of 127.0.0.1:7897; the geosite installer above is independent of the
  # core and applies to Clash Verge's own data directory.
}
