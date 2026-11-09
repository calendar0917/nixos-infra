{ lib, pkgs, ... }:

{
  # LazyVim is imported only by nixosConfigurations.main (see flake.nix).
  # It owns the normal Neovim configuration path, so plain `nvim` (and
  # EDITOR/VISUAL from nvim.nix) starts LazyVim on main.
  programs.lazyvim = {
    enable = true;

    # Write to ~/.config/nvim rather than a separate NVIM_APPNAME, so there
    # is one Neovim configuration on this host and no `lv` wrapper to
    # remember. The mini host does not import this module.
    appName = "nvim";

    # Plugins are still resolved and built by lazyvim-nix from LazyVim's
    # pinned plugin set. Nothing is downloaded by lazy.nvim at runtime.
    pluginSource = "latest";

    extras = {
      lang.nix.enable = true;
      lang.python.enable = true;
      lang.json.enable = true;
      lang.yaml.enable = true;

      # LazyVim v16 defaults its completion group to blink.cmp. Importing the
      # extra keeps that plugin in the Nix-managed set instead of letting
      # lazy.nvim clone it at first start.
      coding.blink.enable = true;
    };

    # Nix owns the language servers, formatters and linters. Mason's runtime
    # installer stays disabled below.
    extraPackages = with pkgs; [
      nil
      nixfmt

      pyright
      ruff

      bash-language-server
      shellcheck
      shfmt

      vscode-langservers-extracted
      yaml-language-server

      stylua
    ];

    plugins = {
      # Disable Mason's installer UI and its lspconfig bridge. The LazyVim
      # extras still configure nvim-lspconfig normally; servers are resolved
      # from the packages above through PATH.
      mason = ''
        return {
          { "mason-org/mason.nvim", enabled = false },
          { "mason-org/mason-lspconfig.nvim", enabled = false },
        }
      '';

      # Make the Nix-provided servers explicit. mason = false documents that
      # these binaries come from extraPackages, not from Mason. pyright is the
      # only Python type checker; ruff is the linter/formatter server.
      lsp = ''
        return {
          "neovim/nvim-lspconfig",
          opts = {
            servers = {
              nil_ls = { mason = false },
              pyright = { mason = false },
              ruff = { mason = false },
              bashls = { mason = false },
              jsonls = { mason = false },
              yamlls = { mason = false },
            },
          },
        }
      '';

      # LazyVim's lualine config calls trouble.statusline through
      # require("trouble"). If trouble is only required as a module, lazy.nvim
      # has not added its runtime directory yet and trouble's source scanner
      # cannot find lsp/diagnostics. Declaring it as a dependency loads the
      # plugin (and its runtimepath) before lualine's config runs.
      lualine = ''
        return {
          "nvim-lualine/lualine.nvim",
          dependencies = { "folke/trouble.nvim" },
        }
      '';

      # blink.cmp normally tries to fetch a pre-built Rust fuzzy matcher
      # binary on first use. That is a runtime download, so use its Lua
      # implementation instead; the feature remains available without the
      # optional binary.
      blink = ''
        return {
          "saghen/blink.cmp",
          opts = {
            fuzzy = {
              implementation = "lua",
            },
          },
        }
      '';

      # blink.cmp's LazyVim extra depends on friendly-snippets, which is not
      # a top-level entry in the LazyVim plugin lock. Pin it to the Nix store
      # for the same reason as yazi.nvim: no runtime Git checkout.
      snippets = ''
        return {
          {
            "rafamadriz/friendly-snippets",
            dir = "${pkgs.vimPlugins.friendly-snippets}",
            lazy = true,
          },
        }
      '';

      # yazi.nvim is loaded straight from the Nix store. Setting dir prevents
      # lazy.nvim from cloning a second copy, and plenary comes from the same
      # Nix-managed plugin set.
      yazi = ''
        return {
          {
            "mikavilpas/yazi.nvim",
            name = "yazi.nvim",
            dir = "${pkgs.vimPlugins.yazi-nvim}",
            event = "VeryLazy",

            dependencies = {
              {
                "nvim-lua/plenary.nvim",
                name = "plenary.nvim",
                dir = "${pkgs.vimPlugins.plenary-nvim}",
                lazy = true,
              },
            },

            keys = {
              {
                "<leader>-",
                "<cmd>Yazi<cr>",
                desc = "Open Yazi",
              },
              {
                "<leader>cw",
                "<cmd>Yazi cwd<cr>",
                desc = "Yazi working directory",
              },
            },

            opts = {
              open_for_directories = false,
            },
          },
        }
      '';
    };
  };

  # Two modules write ~/.config/nvim/init.lua: lazyvim-nix (the LazyVim boot
  # code) and Home Manager's Neovim module (node/python3 provider settings).
  # Both are `types.lines`, so the values concatenate; only `enable` differs
  # and the Neovim module turns it off when it thinks the file is sideloaded.
  # Force the merged file on instead of overriding either module's content.
  xdg.configFile."nvim/init.lua".enable = lib.mkForce true;
}
