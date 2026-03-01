local config = require("taskmeister.config")
local api = require("taskmeister.api")

local M = {}

-- Create a namespace for taskmeister extmarks
local ns_id = vim.api.nvim_create_namespace("taskmeister")

-- Simple markdown rendering for descriptions
local function render_markdown(text)
  if not text or text == "" then return { "" } end
  local lines = vim.split(text, "\n")
  local rendered = {}
  for _, line in ipairs(lines) do
    line = line:gsub("%*%*(.-)%*%*", "**%1**") -- Preserve bold
    line = line:gsub("%*(.-)%*", "*%1*") -- Preserve italic
    line = line:gsub("`(.-)`", "`%1`") -- Preserve code
    table.insert(rendered, line)
  end
  return rendered
end

function M.render_work_item(bufnr, item, is_new)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
  local opts = config.options

    -- Header with work item ID and type
  local work_item_type = item.fields and item.fields["System.WorkItemType"] or (is_new and item.type or "")
  local icon = (config.ui and config.ui.icons and config.ui.icons[work_item_type] or "• ") or "• "
  local id = item.id or "New"
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { string.format("%s #%s %s", icon, id, work_item_type) })
  vim.api.nvim_buf_add_highlight(bufnr, ns_id, "TaskmeisterBlue", 0, 0, -1)

  -- Title (editable content, non-editable label)
  local title = (item.fields and item.fields["System.Title"] or "") or ""
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { title or " " })
  vim.api.nvim_buf_set_extmark(bufnr, ns_id, 1, 0, {
    virt_text = { { "Title ", "TaskmeisterBlue" } },
    virt_text_pos = "inline",
  })

  -- Details (state, assigned) with bubbles
  local state = (item.fields and item.fields["System.State"] or "New") or "New"
  if state == "" then state = " " end
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { state })
  vim.api.nvim_buf_set_extmark(bufnr, ns_id, 2, 0, {
    virt_text = { { "State ", "TaskmeisterBlue" } },
    virt_text_pos = "inline",
  })
  local state_line = vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1] or ""
  if state_line ~= "" then
    local state_icon = (config.ui and config.ui.icons and config.ui.icons["state_" .. string.lower(state)] or { icon = "", hl = "TaskmeisterBlue" }) or { icon = "", hl = "TaskmeisterBlue" }
    local col = math.min(#state_line, #state)
    if col > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, 2, col, {
        virt_text = { { (config.ui and config.ui.bubble_delimiter or "│") .. (state_icon.icon or "") .. (config.ui and config.ui.bubble_delimiter or "│"), state_icon.hl or "TaskmeisterBlue" } },
        virt_text_pos = "inline",
      })
    end
  end

  local assigned = (item.fields and item.fields["System.AssignedTo"] and type(item.fields["System.AssignedTo"].displayName) == "string" and item.fields["System.AssignedTo"].displayName or "Unassigned") or "Unassigned"
  if assigned == "" then assigned = " " end
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { assigned })
  vim.api.nvim_buf_set_extmark(bufnr, ns_id, 3, 0, {
    virt_text = { { "Assigned ", "TaskmeisterBlue" } },
    virt_text_pos = "inline",
  })
  local assigned_line = vim.api.nvim_buf_get_lines(bufnr, 3, 4, false)[1] or ""
  if assigned_line ~= "" then
    local assigned_icon = (config.ui and config.ui.icons and config.ui.icons.assigned or "󰘵 ") or "• "
    local col = math.min(#assigned_line, #assigned)
    if col > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, 3, col, {
        virt_text = { { (config.ui and config.ui.bubble_delimiter or "│") .. assigned_icon .. (config.ui and config.ui.bubble_delimiter or "│"), "TaskmeisterBlue" } },
        virt_text_pos = "inline",
      })
    end
  end

  -- Description (editable content, non-editable label)
  local description = (item.fields and item.fields["System.Description"] or "") or ""
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "" })
  vim.api.nvim_buf_set_extmark(bufnr, ns_id, 4, 0, {
    virt_text = { { "Description", "TaskmeisterBlue" } },
    virt_text_pos = "eol",
  })
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, render_markdown(description))

  -- Timeline/Comments
  local history = item.id and api.get_work_item_history(item.id) or {}
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "" })
  vim.api.nvim_buf_set_extmark(bufnr, ns_id, vim.api.nvim_buf_line_count(bufnr) - 1, 0, {
    virt_text = { { "Timeline", "TaskmeisterBlue" } },
    virt_text_pos = "eol",
  })
  for i, event in ipairs(history) do
    local indent = string.rep(" ", config.ui and config.ui.timeline_indent or 2)
    local marker = (config.ui and config.ui.icons and config.ui.icons[event.type] or "• ") or "• "
    local timestamp = event.timestamp or "N/A"
    local user = event.user or "System"
    local header_hl = event.type == "comment" and "TaskmeisterComment" or "TaskmeisterBlue"
    local header = string.format("%s%s %s %s", indent, marker, user, timestamp)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { header })
    local event_lines = render_markdown(event.value or "")
    for _, line in ipairs(event_lines) do
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { indent .. "  " .. line })
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, header_hl, vim.api.nvim_buf_line_count(bufnr) - 1, 0, -1)
    end
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { indent .. string.rep("─", 60) })
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, vim.api.nvim_buf_line_count(bufnr) - #event_lines - 2, 0, {
      virt_text = { { marker, header_hl } },
      virt_text_pos = "inline",
    })
    -- Add reactions bubble if event.type == "comment"
    if event.type == "comment" then
      local reactions = api.get_comment_reactions(id, event.rev) or {}
      local reaction_bubble = ""
      for r_type, count in pairs(reactions) do
        local r_icon = config.ui.icons[r_type] or ""
        if count > 0 then
          reaction_bubble = reaction_bubble .. " [" .. r_icon .. " " .. count .. "]"
        end
      end
      if reaction_bubble ~= "" then
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, vim.api.nvim_buf_line_count(bufnr) - #event_lines - 3, #header, {
          virt_text = { { reaction_bubble, "TaskmeisterBlue" } },
          virt_text_pos = "inline",
        })
      end
    end
  end

  if is_new then
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
  end

  -- Set buffer options
  vim.api.nvim_buf_set_option(bufnr, "filetype", "taskmeister")
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_option(bufnr, "syntax", "markdown") -- Enable markdown syntax highlighting
end

function M.parse_changes(lines, data)
  local parsed = {
    title = data.fields and data.fields["System.Title"] or "",
    description = data.fields and data.fields["System.Description"] or "",
    state = data.fields and data.fields["System.State"] or "New",
    assigned_to = data.fields and data.fields["System.AssignedTo"] and data.fields["System.AssignedTo"].uniqueName or "",
  }
  local in_desc = false
  local desc_lines = {}
  local line_idx = 1
  for i, line in ipairs(lines) do
    if i == 2 then
      parsed.title = line or ""
    elseif i == 3 then
      parsed.state = line or ""
    elseif i == 4 then
      parsed.assigned_to = line or ""
    elseif line == "" and i > 4 then
      in_desc = true
      line_idx = i + 1
    elseif in_desc and line:match("^%s*$") then
      in_desc = false
    elseif in_desc then
      table.insert(desc_lines, line)
    end
  end
  parsed.description = table.concat(desc_lines, "\n")
  return parsed
end

return M
