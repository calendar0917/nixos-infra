return {
  "MeanderingProgrammer/render-markdown.nvim",
  dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-mini/mini.nvim" },
  ft = { "markdown", "obsidian" }, -- 确保在这些文件类型下开启
  config = function()
    require("render-markdown").setup({
      -- 配合 obsidian.nvim 的设置
      anti_conceal = {
        enabled = false, -- 关闭以避免光标所在行跳动
      },
      win_options = {
        -- 渲染时不要强制更高的 conceallevel，减少隐藏导致的阅读负担
        conceallevel = { rendered = 2 },
      },
      heading = {
        -- 降低标题的“块状感”，保留轻量强调
        position = "inline",
        width = "block",
        left_pad = 0,
        right_pad = 0,
        border = false,
        sign = false,
      },
      code = {
        -- 让代码块更轻量、稳定，不隐藏边界
        conceal_delimiters = false,
        language = false,
        width = "block",
        left_pad = 1,
        right_pad = 1,
        border = "none",
      },
      checkbox = {
        enabled = true,
        -- 这里可以自定义复选框样式
      },
    })
  end,
}
