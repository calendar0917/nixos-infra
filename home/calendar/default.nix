{
  ...
}:

{
  imports = [
    ./shell.nix
    ./neovim.nix
    ./desktop/niri.nix
    ./desktop/sway.nix
    ./desktop/waybar/sway.nix
    ./desktop/waybar/niri.nix
  ];

  home = {
    username = "calendar";
    homeDirectory = "/home/calendar";
    # Keep this at the version from the first Home Manager activation.
    stateVersion = "25.05";
  };

  # Nautilus is the graphical handler for directories. The desktop ID comes
  # from pkgs.nautilus (org.gnome.Nautilus.desktop), not from a Dolphin name.
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "inode/directory" = "org.gnome.Nautilus.desktop";
    };
  };

  # Fcitx5 is started once by systemd (modules/desktop/common.nix). Its
  # package also ships an XDG autostart entry; mask that user-level entry so
  # the niri and Sway XDG autostart targets cannot start a second process.
  xdg.configFile."autostart/org.fcitx.Fcitx5.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Fcitx5 (managed by systemd)
    Exec=true
    Hidden=true
  '';
}
