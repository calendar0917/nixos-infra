{
  ...
}:

{
  imports = [
    ./shell.nix
    ./terminal.nix
    ./helix.nix
    ./apps.nix
    ./tmux.nix
    ./desktop/niri.nix
    ./desktop/displays.nix
    ./desktop/clipboard.nix
    ./desktop/lock.nix
    ./desktop/power.nix
    ./desktop/shell.nix
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

  # KeePassXC is installed by Home Manager. `settings` is deliberately left
  # empty: writing keepassxc.ini from Nix would link it read-only from the
  # store and make the GUI's settings unchangeable. The database and master
  # password live outside this repository; no KDBX path is baked in here.
  programs.keepassxc.enable = true;

  # Nautilus is the graphical handler for directories. The desktop ID comes
  # from pkgs.nautilus (org.gnome.Nautilus.desktop), not from a Dolphin name.
  # Firefox is the system browser (modules/base.nix) and also handles HTTP(S)
  # links. The main-only document/image/video handlers live in apps.nix.
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "inode/directory" = "org.gnome.Nautilus.desktop";
      "text/html" = "firefox.desktop";
      "x-scheme-handler/http" = "firefox.desktop";
      "x-scheme-handler/https" = "firefox.desktop";
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

  # Declarative input method profile so the list (English (US), Rime, Pinyin)
  # survives Fcitx5 restarts and reorderings done from the tray. Rime is
  # DefaultIM, so the preferred Chinese method is Rime and not Pinyin.
  xdg.configFile."fcitx5/profile".text = ''
    [GroupOrder]
    0=Default

    [Groups/0]
    Name=Default
    Default Layout=us
    DefaultIM=rime

    [Groups/0/Items/0]
    Name=keyboard-us

    [Groups/0/Items/1]
    Name=rime

    [Groups/0/Items/2]
    Name=pinyin
  '';

  # Rime Ice is provided by the rime-ice data package (see
  # modules/desktop/common.nix); only this patch file is managed here. The rest
  # of ~/.local/share/fcitx5/rime stays writable and owned by the user, so the
  # learned dictionaries (*.userdb), custom phrases and build/ are untouched.
  home.file.".local/share/fcitx5/rime/default.custom.yaml".text = ''
    patch:
      __include: rime_ice_suggestion:/
      __patch:
        schema_list:
          - schema: rime_ice
        "menu/page_size": 7
  '';
}
