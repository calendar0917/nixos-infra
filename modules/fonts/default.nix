{ lib, pkgs, ... }:

let
  maple-mono = pkgs.stdenvNoCC.mkDerivation {
    pname = "maple-mono-nf-cn";
    version = "7.9";
    src = pkgs.fetchzip {
      url = "https://github.com/subframe7536/maple-font/releases/download/v7.9/MapleMono-NF-CN-Unhinted.zip";
      hash = lib.fakeHash;
    };
    installPhase = ''
      mkdir -p $out/share/fonts/truetype
      cp *.ttf $out/share/fonts/truetype/
    '';
  };
in
{
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-color-emoji
    maple-mono
  ];
}
