# Plain package definition for the main host's unified terminal system control
# center. This is not a Home Manager module: shell.nix installs the package and
# waybar/niri.nix imports the same definition for a stable absolute path in its
# on-click commands.
{ pkgs }:

pkgs.writeShellApplication {
  name = "niri-system-control";

  # fzf is the menu layer; every real control stays in the existing system
  # service or command-line tool. The interactive Fish shell's PATH, aliases
  # and functions are deliberately not used.
  runtimeInputs = with pkgs; [
    btop
    brightnessctl
    bluetui
    coreutils
    fzf
    kitty
    networkmanager
    power-profiles-daemon
    systemd
    wiremix
  ];

  text = builtins.readFile ./system-control.sh;
}
