return {
  {
    "epwalsh/obsidian.nvim",
    version = "*",
    lazy = true,
    ft = "markdown",
    dependencies = { "nvim-lua/plenary.nvim", "nvim-telescope/telescope.nvim" },
    keys = {
      { "<leader>on", "<cmd>ObsidianNew<cr>", desc = "New Obsidian Note" },
      { "<leader>os", "<cmd>ObsidianSearch<cr>", desc = "Search Obsidian" },
      { "<leader>ot", "<cmd>ObsidianTemplate<cr>", desc = "Insert Template" },
      { "<leader>ob", "<cmd>ObsidianBacklinks<cr>", desc = "Show Backlinks" },
      { "<leader>ox", "<cmd>ObsidianToggleCheckbox<cr>", desc = "Toggle Checkbox" },
      -- 修复 gf
      {
        "gf",
        function()
          if require("obsidian").util.cursor_on_markdown_link() then
            return "<cmd>ObsidianFollowLink<CR>"
          else
            return "gf"
          end
        end,
        expr = true,
        desc = "Follow Link",
      },
    },
    opts = {
      workspaces = {
        {
          name = "personal",
          path = "~/Documents/quartz/content",
        },
      },
      notes_subdir = "未归档",
      new_notes_location = "notes_subdir",
      daily_notes = {
        folder = "00_日志",
        date_format = "%Y-%m-%d",
        alias_format = "%Y-%m-%d",
        default_tags = { "journal" },
      },
      templates = {
        folder = "00_模板",
        date_format = "%Y-%m-%d",
        time_format = "%H:%M",
      },
      completion = {
        nvim_cmp = true,
        min_chars = 2,
      },
      -- 解决 No picker configured
      picker = {
        name = "telescope.nvim",
      },
      -- 界面美化配合
      ui = {
        enable = true,
        update_debounce = 200,
        checkboxes = {}, -- 可以留空，让 render-markdown 处理
      },
    },
    config = function(_, opts)
      require("obsidian").setup(opts)
    end,
  },
  {
    "saghen/blink.cmp",
    dependencies = { "saghen/blink.compat" },
    opts = function(_, opts)
      -- 1. 将 obsidian 的源加入到默认列表（不要直接覆盖原来的 default）
      opts.sources.default =
        vim.list_extend(opts.sources.default or {}, { "obsidian", "obsidian_new", "obsidian_tags" })

      -- 2. 配置提供者
      opts.sources.providers.obsidian = {
        name = "obsidian",
        module = "blink.compat.source",
      }
      opts.sources.providers.obsidian_new = {
        name = "obsidian_new",
        module = "blink.compat.source",
      }
      opts.sources.providers.obsidian_tags = {
        name = "obsidian_tags",
        module = "blink.compat.source",
      }
    end,
  },
}
