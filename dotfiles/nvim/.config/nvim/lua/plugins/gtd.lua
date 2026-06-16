local function obsidian_cmd(cmd)
  vim.cmd(cmd)
end

local function obsidian_search(query)
  obsidian_cmd("ObsidianSearch " .. query)
end

local function obsidian_new()
  obsidian_cmd("ObsidianNew")
end

return {
  "epwalsh/obsidian.nvim",
  keys = {
    { "<leader>ogc", obsidian_new, desc = "GTD Capture" },
    { "<leader>ogi", function() obsidian_search("#gtd") end, desc = "GTD Inbox" },
    { "<leader>ogp", function() obsidian_search("#project") end, desc = "GTD Projects" },
    { "<leader>ogn", function() obsidian_search("#next") end, desc = "GTD Next" },
    { "<leader>ogw", function() obsidian_search("#waiting") end, desc = "GTD Waiting" },
    { "<leader>ogs", function() obsidian_search("#someday") end, desc = "GTD Someday" },
    { "<leader>ogr", function() obsidian_search("#review") end, desc = "GTD Review" },
  },
}
