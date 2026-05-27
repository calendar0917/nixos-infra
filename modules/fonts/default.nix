{ lib, pkgs, ... }:

let
  maple-mono = pkgs.stdenvNoCC.mkDerivation {
    pname = "maple-mono-nf-cn";
    version = "7.9";
    src = pkgs.fetchzip {
      url = "https://github.com/subframe7536/maple-font/releases/download/v7.9/MapleMono-NF-CN-Unhinted.zip";
      hash = "sha256-8v90s5TAolpbfoSwXdVmKCsFJ9AJ71DT/WRgBV2S94Y=";
      stripRoot = false;
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
