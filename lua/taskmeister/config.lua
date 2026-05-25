local M = {}

M.defaults = {
  personal_access_token = nil,
  organization = nil,
  project = nil,
  base_url = 'https://dev.azure.com',
  show_work_item_icon = false,
  enable_work_item_details_auto_command = false,
  dashboard = {
    max_items = 100,
    stale_after_days = 14,
    recent_days = 7,
    blocked_tags = { "Blocked" },
    closed_states = { "Closed", "Done", "Removed" },
    active_states = { "Active", "In Progress", "Committed", "Doing" },
    new_states = { "New", "To Do", "Proposed" },
  },
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
    { mode = "n", lhs = "<leader>tmd", rhs = ':Taskmeister details<CR>', opts = { noremap = true, silent = true, desc = "Taskmeister show work item details" } },
    { mode = "n", lhs = "<leader>tmv", rhs = ':Taskmeister vt-show<CR>', opts = { noremap = true, silent = true, desc = "Taskmeister add work item virtual text" } },
    { mode = "n", lhs = "<leader>tmc", rhs = ':Taskmeister vt-clear<CR>', opts = { noremap = true, silent = true, desc = "Taskmeister clear work item virtual text" } },
    { mode = "n", lhs = "<leader>tmb", rhs = ':Taskmeister browser<CR>', opts = { noremap = true, silent = true, desc = "Taskmeister open work item in browser" } }
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
