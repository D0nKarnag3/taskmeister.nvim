local M = {}

M.defaults = {
  personal_access_token = nil,
  organization = nil,
  project = nil,
  base_url = 'https://dev.azure.com',
  enable_work_item_details_auto_command = false,
}

M.options = {}

function M.set(opts)
  M.options = vim.tbl_extend('force', M.defaults, opts or {})
end

return M
