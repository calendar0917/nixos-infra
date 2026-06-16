return {
  "CRAG666/code_runner.nvim",
  config = true,
  keys = {
    { "<leader>r", "<cmd>RunCode<cr>", desc = "Run Code" },
  },
  opts = {
    mode = "term", -- 运行模式：float (浮动窗口), term (分屏), toggleterm
    filetype = {
      java = "cd $dir && javac $fileName && java $fileNameWithoutExt",
      python = "python3 -u",
      typescript = "deno run",
      rust = "cd $dir && rustc $fileName && $dir/$fileNameWithoutExt",
      c = "cd $dir && gcc $fileName -o /tmp/$fileNameWithoutExt && /tmp/$fileNameWithoutExt",
      cpp = "cd $dir && g++ $fileName -o /tmp/$fileNameWithoutExt && /tmp/$fileNameWithoutExt",
    },
  },
}
