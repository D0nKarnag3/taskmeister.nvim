local M = {}

M.defaults = {
  personal_access_token = nil,
  organization = nil,
  project = nil,
  base_url = 'https://dev.azure.com',
  show_work_item_icon = false,
  enable_work_item_details_auto_command = false,
  ui = {
    use_signcolumn = true,
    timeline_indent = 2,
    bubble_delimiter = "│",
    icons = {
      comment = "󰌶 ",
      state_change = "󰷬 ",
      assigned = "󰘵 ",
      state_active = { icon = "󰄬 ", hl = "TaskmeisterGreen" },
      state_resolved = { icon = "󰄲 ", hl = "TaskmeisterPurple" },
      Task = "󰗀 ",
      Bug = "󰨰 ",
      Feature = "󰉗 ",
      ["User Story"] = "📋 ",
      thumbs_up = "👍",
      thumbs_down = "👎",
      laugh = "😄",
      confused = "😕",
      heart = "❤️",
      hooray = "🎉",
      rocket = "🚀",
      eyes = "👀",
    },
  },
  keymaps = {
    { mode = "n", lhs = "<leader>ad", rhs = ':AzureGetWorkItem<CR>', opts = { noremap = true, silent = true, desc = "Azure DevOps show detailed informail of work item" } },
    { mode = "n", lhs = "<leader>av", rhs = ':AzureShowWorkItemVirtualText<CR>', opts = { noremap = true, silent = true, desc = "Azure DevOps Add work item details" } },
    { mode = "n", lhs = "<leader>ac", rhs = ':AzureClearWorkItemVirtualText<CR>', opts = { noremap = true, silent = true, desc = "Azure DevOps Open work item in browser" } },
    { mode = "n", lhs = "<leader>ao", rhs = ':AzureOpenWorkItemInBrowser<CR>', opts = { noremap = true, silent = true, desc = "Azure DevOps Open work item in browser" } }
  }
}

M.options = {}

function M.set(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  if not M.options.base_url or not M.options.personal_access_token or not M.options.organization or not M.options.project then
    error("taskmeister.nvim: Missing required config (base_url, personal_access_token, organization, or project)")
  end
  if not M.options.ui or not M.options.ui.icons then
    error("taskmeister.nvim: Missing ui or ui.icons in config")
  end
  if M.options.keymaps then
    for _, map in ipairs(M.options.keymaps) do
      vim.keymap.set(map.mode, map.lhs, map.rhs, map.opts)
    end
  end

  --M.options = vim.tbl_extend('force', M.defaults, opts or {})
--
  --if M.options.keymaps then
    --for _, map in ipairs(M.options.keymaps) do
      --vim.keymap.set(map.mode, map.lhs, map.rhs, map.opts)
    --end
  --end
end

function M.get()
  return M.options
end

return M
