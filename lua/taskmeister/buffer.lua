local config = require("taskmeister.config")
local api = require("taskmeister.api")
local badges = require("taskmeister.badges")

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
  local opts = config.options

    -- Header with work item ID and type
  local work_item_type = item.fields and item.fields["System.WorkItemType"] or (is_new and item.type or "")
  local ui = opts.ui or {}
  local icons = ui.icons or {}
  local icon = icons[work_item_type] or "• "
  local id = item.id or "New"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { string.format("%s #%s %s", icon, id, work_item_type) })
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
    local state_icon = icons["state_" .. string.lower(state)] or { icon = "", hl = "TaskmeisterBlue" }
    local col = math.min(#state_line, #state)
    if col > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, 2, col, {
        virt_text = { { (ui.bubble_delimiter or "│") .. (state_icon.icon or "") .. (ui.bubble_delimiter or "│"), state_icon.hl or "TaskmeisterBlue" } },
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
    local assigned_icon = icons.assigned or "󰘵 "
    local col = math.min(#assigned_line, #assigned)
    if col > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, 3, col, {
        virt_text = { { (ui.bubble_delimiter or "│") .. assigned_icon .. (ui.bubble_delimiter or "│"), "TaskmeisterBlue" } },
        virt_text_pos = "inline",
      })
    end
  end

  local tags = (item.fields and item.fields["System.Tags"] or "") or ""
  local tag_chunks = badges.tag_chunks(tags)
  local tag_prefix = "Labels: "
  local tag_line = tag_prefix .. (#tag_chunks > 0 and tags or "none")
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { tag_line })
  local tag_line_nr = vim.api.nvim_buf_line_count(bufnr) - 1
  vim.api.nvim_buf_add_highlight(bufnr, ns_id, "TaskmeisterBlue", tag_line_nr, 0, 7)
  if #tag_chunks > 0 then
    badges.decorate_tag_field(bufnr, ns_id, tag_line_nr, tag_line, #tag_prefix)
  end

  -- Description (editable content, non-editable label)
  local description = (item.fields and item.fields["System.Description"] or "") or ""
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "" })
  local description_label_line = vim.api.nvim_buf_line_count(bufnr) - 1
  vim.api.nvim_buf_set_extmark(bufnr, ns_id, description_label_line, 0, {
    virt_text = { { "Description", "TaskmeisterBlue" } },
    virt_text_pos = "eol",
  })
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, render_markdown(description))

  -- Timeline/Comments
  local history = item.id and api.get_work_item_history(item.id) or {}
  local comments = item.id and api.get_work_item_comments(item.id) or {}
  local comment_index = 0
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "" })
  vim.api.nvim_buf_set_extmark(bufnr, ns_id, vim.api.nvim_buf_line_count(bufnr) - 1, 0, {
    virt_text = { { "Timeline", "TaskmeisterBlue" } },
    virt_text_pos = "eol",
  })
  for i, event in ipairs(history) do
    local indent = string.rep(" ", ui.timeline_indent or 2)
    local marker = icons[event.type] or "• "
    local timestamp = event.timestamp or "N/A"
    local user = event.user or "System"
    local header_hl = event.type == "comment" and "TaskmeisterComment" or "TaskmeisterBlue"
    local header = string.format("%s%s %s %s", indent, marker, user, timestamp)
    local header_line = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { header })
    local event_lines = render_markdown(event.value or "")
    for _, line in ipairs(event_lines) do
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { indent .. "  " .. line })
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, header_hl, vim.api.nvim_buf_line_count(bufnr) - 1, 0, -1)
    end
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { indent .. string.rep("─", 60) })
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, header_line, 0, {
      virt_text = { { marker, header_hl } },
      virt_text_pos = "inline",
    })
    -- Add reactions bubble if event.type == "comment"
    if event.type == "comment" then
      comment_index = comment_index + 1
      local comment = comments[comment_index] or {}
      local reaction_chunks = badges.reaction_chunks(comment.reactions or {}, icons)
      if #reaction_chunks > 0 then
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, header_line, #header, {
          virt_text = reaction_chunks,
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
    tags = data.fields and data.fields["System.Tags"] or "",
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
    elseif i == 5 then
      parsed.tags = (line or ""):gsub("^Labels:%s*", "")
      if parsed.tags == "none" then
        parsed.tags = ""
      end
    elseif line == "" and i > 5 then
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
