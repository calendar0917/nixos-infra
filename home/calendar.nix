{ config, lib, pkgs, cc-switch-cli, ... }:
let
  out = config.lib.file.mkOutOfStoreSymlink;
in {
  home.username = "calendar";
  home.homeDirectory = "/home/calendar";

  # 改了即时生效，不用 rebuild
  xdg.configFile = {
    "niri/config.kdl".source = out "${config.home.homeDirectory}/nixos/modules/features/niri/config.kdl";
    "niri/dms".source       = out "${config.home.homeDirectory}/nixos/modules/features/niri/dms";
    fish.source              = out "${config.home.homeDirectory}/nixos/dotfiles/fish/.config/fish";
    kitty.source             = out "${config.home.homeDirectory}/nixos/dotfiles/kitty/.config/kitty";
    kanshi.source            = out "${config.home.homeDirectory}/nixos/dotfiles/kanshi/.config/kanshi";
    nvim.source              = out "${config.home.homeDirectory}/nixos/dotfiles/nvim/.config/nvim";
  };

  home.packages = with pkgs; [
    cc-switch-cli
    hugo
    taskwarrior3
    taskwarrior-tui
  ];

  home.stateVersion = "25.05";
}
