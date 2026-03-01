local api = require('taskmeister.api')
local config = require('taskmeister.config')

local M = {}
local namespace_id = vim.api.nvim_create_namespace('virtual_text_matcher')

function M.clear_virtual_text(bufnr, namespace_id)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace_id, 0, -1)
end

function M.add_virtual_text(bufnr, namespace_id, line, col, text)
  vim.api.nvim_buf_set_extmark(bufnr, namespace_id, line, col, {
    virt_text = {{ text, 'Comment' }},
    virt_text_pos = 'inline'
  })
end

function M.show_work_item_virtual_text()
  local bufnr = vim.api.nvim_get_current_buf()
  M.clear_virtual_text(bufnr, namespace_id)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local pattern = 'WI(%d+)'

  local ids = {}
  local seen = {}
  for _, line in ipairs(lines) do
    for id in line:gmatch(pattern) do
      if not seen[id] then
        seen[id] = true
        table.insert(ids, tonumber(id))
      end
    end
  end

  if #ids == 0 then
    return
  end

  local items = api.get_work_items_batch(ids)
  local work_item_map = {}
  for _, item in ipairs(items or {}) do
    local id = tostring(item.id)
    work_item_map[id] = {
      work_item_type = item.fields['System.WorkItemType'],
      title = item.fields['System.Title']
    }
  end

  for i, line in ipairs(lines) do
    local start = 1
    while true do
      local s, e, id = line:find('WI(%d+)', start)
      if not s then
        break
      end
      local work_item_type = work_item_map[id] and work_item_map[id].work_item_type or 'Unknown'
      local title = work_item_map[id] and work_item_map[id].title or 'Unknown'
      local work_item_icon = ''
      if config.options.show_work_item_icon == true then
        work_item_icon = get_unicode_for_work_item_type(work_item_type) .. ' '
      end
      M.add_virtual_text(bufnr, namespace_id, i - 1, s - 1, work_item_icon .. work_item_type .. ': ')
      M.add_virtual_text(bufnr, namespace_id, i - 1, e, ' ' .. title)
      start = e + 1
    end
  end
end

function M.clear_current_buffer_virtual_text()
  M.clear_virtual_text(vim.api.nvim_get_current_buf(), namespace_id)
end

function get_unicode_for_work_item_type(work_item_type)
  local unicode_character = ""

  if work_item_type == "Bug" then
      unicode_character = ""
  elseif work_item_type == "Task" then
      unicode_character = ""
  elseif work_item_type == "User Story" then
      unicode_character = ""
  elseif work_item_type == "Feature" then
      unicode_character = ""
  elseif work_item_type == "Test Case" then
      unicode_character = "󰙨"
  else
      unicode_character = ""
  end

  return unicode_character
end

function M.test()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "This feature requires the WI88 to be implemented" })

    local bufnr = vim.api.nvim_get_current_buf()

    local line = 0
    local col_start = 26
    local col_end = col_start + 4

    local ns_id = vim.api.nvim_create_namespace('example_ns')

  vim.api.nvim_buf_set_extmark(bufnr, ns_id, line, col_start, {
    virt_text = {{ 'Task ', 'Comment' }},
    virt_text_pos = 'inline'
    --virt_text_win_col = col_start - 5
    --virt_text_pos = 'overlay'
  })

  vim.api.nvim_buf_set_extmark(bufnr, ns_id, line, col_end, {
    virt_text = {{ ' Implement factory pattern', 'Comment' }},
    virt_text_pos = 'inline'
    --virt_text_win_col = col_end
    --virt_text_pos = 'overlay'
  })
end

function M.jump_to_work_item()
  local line = vim.api.nvim_get_current_line()
  local id = line:match("WI(%d+)")
  if id then
    require("taskmeister.ui").open_work_item(id)
  end
end

return M
