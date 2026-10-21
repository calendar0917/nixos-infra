{
  ...
}:

{
  imports = [
    ./shell.nix
    ./neovim.nix
    ./desktop/niri.nix
    ./desktop/sway.nix
  ];

  home = {
    username = "calendar";
    homeDirectory = "/home/calendar";
    # Keep this at the version from the first Home Manager activation.
    stateVersion = "25.05";
  };
}
