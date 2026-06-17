{ lib, pkgs, ... }:

{
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
    maple-mono
  ];

  fonts.fontconfig.localConf = builtins.readFile ./fontconfig-cjk.xml;
}
