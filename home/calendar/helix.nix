{
  pkgs,
  ...
}:

{
  # Keep this deliberately small: no plugin manager and no Vim-keybinding
  # emulation layer. The mini host keeps DMS; it does not switch shells
  # because of this module.
  programs.helix = {
    enable = true;
    defaultEditor = true;

    settings = {
      theme = "catppuccin_mocha_terminal";

      editor = {
        line-number = "relative";
        cursorline = true;
        color-modes = true;
        true-color = true;
        cursor-shape = {
          insert = "bar";
          normal = "block";
          select = "underline";
        };
      };
    };

    # The base Catppuccin theme paints the editing area with an opaque base
    # colour. Clearing only ui.background lets kitty's 90% background show
    # through while selections, status line, line numbers and diagnostics
    # retain their normal Catppuccin styling. Helix accepts an empty style
    # object for this override.
    themes.catppuccin_mocha_terminal = {
      inherits = "catppuccin_mocha";
      "ui.background" = { };
    };

    extraPackages = with pkgs; [
      bash-language-server
      nil
      nixfmt
      pyright
      vscode-langservers-extracted
      yaml-language-server
    ];

    languages = {
      language-server = {
        nil.command = "nil";
        pyright = {
          command = "pyright-langserver";
          args = [ "--stdio" ];
        };
        bashls = {
          command = "bash-language-server";
          args = [ "start" ];
        };
        vscode-json-language-server = {
          command = "vscode-json-language-server";
          args = [ "--stdio" ];
        };
        yaml-language-server = {
          command = "yaml-language-server";
          args = [ "--stdio" ];
        };
      };

      # Select exactly one server per language. In particular, do not leave
      # the default Python server list in place alongside pyright: that would
      # start two type-checking services for the same buffer.
      language = [
        {
          name = "nix";
          language-servers = [ "nil" ];
          formatter = {
            command = "nixfmt";
          };
        }
        {
          name = "python";
          language-servers = [ "pyright" ];
        }
        {
          name = "bash";
          language-servers = [ "bashls" ];
        }
        {
          name = "json";
          language-servers = [ "vscode-json-language-server" ];
        }
        {
          name = "yaml";
          language-servers = [ "yaml-language-server" ];
        }
      ];
    };
  };
}
