local api = require('azure_devops.api')

local M = {}

function M.clear_virtual_text(bufnr, namespace_id)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace_id, 0, -1)
end

function M.add_virtual_text(bufnr, namespace_id, line, col, text)
  vim.api.nvim_buf_set_extmark(bufnr, namespace_id, line, col, {
    virt_text = {{ text, 'Comment' }},
    virt_text_pos = 'inline'
  })
end

function M.highlight_matches()
  local bufnr = vim.api.nvim_get_current_buf()
  local namespace_id = vim.api.nvim_create_namespace('virtual_text_matcher')

  M.clear_virtual_text(bufnr, namespace_id)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local pattern = 'WI%d+'

  local ids = {}
  for _, line in ipairs(lines) do
    for matched_word in line:gmatch(pattern) do
      local id = string.sub(matched_word, 3)
      table.insert(ids, id)
    end
  end

  api.get_workitem_type_and_title(ids, function(data)
    if data == nil then
      return
    end
    vim.schedule(function()
      local result = vim.fn.json_decode(table.concat(data, '\n'))
      if result and result.value then
        local work_item_map = {}
        for _, item in ipairs(result.value) do
          local id = tostring(item.id)
          work_item_map[id] = {
            work_item_type = item.fields['System.WorkItemType'],
            title = item.fields['System.Title']
          }
        end

        for i, line in ipairs(lines) do
          local start = 1
          while true do
            local s, e = string.find(line, pattern, start)
            if not s then break end
            local matched_word = string.sub(line, s, e)
            local id = string.sub(matched_word, 3)
            local work_item_type = work_item_map[id] and work_item_map[id].work_item_type or 'Unknown'
            local title = work_item_map[id] and work_item_map[id].title or 'Unknown'
            M.add_virtual_text(bufnr, namespace_id, i - 1, s - 1, work_item_type .. ' ')
            M.add_virtual_text(bufnr, namespace_id, i - 1, e, ' ' .. title)
            start = e + 1
          end
        end
      end
    end)
  end)
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

return M
