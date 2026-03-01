local ui = require("taskmeister.ui")
local api = require("taskmeister.api")

local M = {}

function M.setup_keymaps(bufnr)
  -- Already in init.lua autocmd
end

function M.add_comment(bufnr)
  -- Append new editable section at end
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "--- New Comment ---" })
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "" })  -- Empty line for comment
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "--- End Comment ---" })
  -- Position cursor
  vim.api.nvim_win_set_cursor(0, {vim.api.nvim_buf_line_count(bufnr) - 1, 0})
  -- On sync, parse and add via API update (history field)
end

function M.change_state(bufnr)
  local new_state = vim.fn.input("New State (e.g., Active, Resolved): ")
  if new_state ~= "" then
    local meta = ui.buffers[bufnr]  -- Access from ui
    local patches = { { op = "replace", path = "/fields/System.State", value = new_state } }
    api.update_work_item(meta.id, patches)
    vim.notify("State changed to " .. new_state)
    ui.sync_buffer(bufnr)  -- Re-render
  end
end

function M.assign_user(bufnr)
  local email = vim.fn.input("Assign to (email): ")
  if email ~= "" then
    local meta = ui.buffers[bufnr]
    local patches = { { op = "replace", path = "/fields/System.AssignedTo", value = email } }
    api.update_work_item(meta.id, patches)
    vim.notify("Assigned to " .. email)
    ui.sync_buffer(bufnr)
  end
end

return M
