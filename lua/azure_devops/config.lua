local M = {}

M.defaults = {
  personal_access_token = nil,
  organization = nil,
  project = nil,
  base_url = 'https://dev.azure.com',
  show_work_item_icon = false,
  enable_work_item_details_auto_command = false,

  keymaps = {
    { mode = "n", lhs = "<leader>ad", rhs = ':AzureGetWorkItem<CR>', { noremap = true, silent = true, desc = "Azure DevOps show detailed informail of work item" } },
    { mode = "n", lhs = "<leader>av", rhs = ':AzureShowWorkItemVirtualText<CR>', { noremap = true, silent = true, desc = "Azure DevOps Add work item details" } },
    { mode = "n", lhs = "<leader>ac", rhs = ':AzureClearWorkItemVirtualText<CR>', { noremap = true, silent = true, desc = "Azure DevOps Open work item in browser" } },
    { mode = "n", lhs = "<leader>ao", rhs = ':AzureOpenWorkItemInBrowser<CR>', { noremap = true, silent = true, desc = "Azure DevOps Open work item in browser" } }
  }
}

M.options = {}

function M.set(opts)
  M.options = vim.tbl_extend('force', M.defaults, opts or {})

  if M.options.keymaps then
    for _, map in ipairs(M.options.keymaps) do
      vim.keymap.set(map.mode, map.lhs, map.rhs, map.opts)
    end
  end
end

return M
