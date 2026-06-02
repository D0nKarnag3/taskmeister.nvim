local api = require("taskmeister.api")
local badges = require("taskmeister.badges")
local buffer = require("taskmeister.buffer")
local config = require("taskmeister.config")

local M = {}

local buffers = {}  -- Track open work items by ID
local edit_ns = vim.api.nvim_create_namespace("taskmeister_edit")
local edit_label_ns = vim.api.nvim_create_namespace("taskmeister_edit_labels")
local edit_tag_ns = vim.api.nvim_create_namespace("taskmeister_edit_tags")
local status_ns = vim.api.nvim_create_namespace("taskmeister_edit_status")
local COMMENTS_MARKER = "──────────────── Comments ────────────────"
local REACTION_TYPES = badges.reaction_types
local EDIT_DIALOG_FIELDS = {
  "System.Id",
  "System.Title",
  "System.WorkItemType",
  "System.State",
  "System.Description",
  "System.AssignedTo",
  "System.Tags",
  "Microsoft.VSTS.Scheduling.OriginalEstimate",
  "Microsoft.VSTS.Scheduling.RemainingWork",
  "Microsoft.VSTS.Scheduling.CompletedWork",
}
local EDIT_FIELD_DEFINITIONS = {
  title = { key = "title", label = "Title", edit_label = "Title: ", path = "/fields/System.Title" },
  state = { key = "state", label = "State", edit_label = "State: ", path = "/fields/System.State" },
  assigned_to = { key = "assigned_to", label = "Assigned To", edit_label = "Assigned To: ", path = "/fields/System.AssignedTo" },
  tags = { key = "tags", label = "Tags", edit_label = "Tags: ", path = "/fields/System.Tags" },
  original_estimate = {
    key = "original_estimate",
    label = "Original estimate",
    edit_label = "Original estimate: ",
    path = "/fields/Microsoft.VSTS.Scheduling.OriginalEstimate",
    numeric = true,
  },
  remaining = {
    key = "remaining",
    label = "Remaining",
    edit_label = "Remaining: ",
    path = "/fields/Microsoft.VSTS.Scheduling.RemainingWork",
    numeric = true,
  },
  completed = {
    key = "completed",
    label = "Completed",
    edit_label = "Completed: ",
    path = "/fields/Microsoft.VSTS.Scheduling.CompletedWork",
    numeric = true,
  },
  description = { key = "description", label = "Description", path = "/fields/System.Description" },
}
local EDIT_BASE_FIELD_ORDER = { "title", "state", "assigned_to", "tags" }
local EDIT_TASK_FIELD_ORDER = { "original_estimate", "remaining", "completed" }

M.buffers = buffers

local function parse_work_item_id(value)
  if not value or value == "" then
    return nil
  end
  local raw = tostring(value)
  local wi_prefixed = raw:match("^WI(%d+)$")
  local num = tonumber(wi_prefixed or raw)
  return num
end

local function split_text(value)
  if not value or value == "" then
    return { "" }
  end
  return vim.split(value, "\n", { plain = true })
end

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function assigned_value(fields)
  local assigned = fields["System.AssignedTo"]
  if type(assigned) == "table" then
    return assigned.uniqueName or assigned.displayName or ""
  end
  if type(assigned) == "string" then
    return assigned
  end
  return ""
end

local function field_string(fields, key)
  local value = fields[key]
  if value == nil then
    return ""
  end
  return tostring(value)
end

local function is_task_item(item)
  local fields = (item or {}).fields or {}
  return fields["System.WorkItemType"] == "Task"
end

local function editor_values_from_item(item)
  local fields = (item or {}).fields or {}
  return {
    title = fields["System.Title"] or "",
    state = fields["System.State"] or "New",
    assigned_to = assigned_value(fields),
    tags = fields["System.Tags"] or "",
    original_estimate = field_string(fields, "Microsoft.VSTS.Scheduling.OriginalEstimate"),
    remaining = field_string(fields, "Microsoft.VSTS.Scheduling.RemainingWork"),
    completed = field_string(fields, "Microsoft.VSTS.Scheduling.CompletedWork"),
    description = fields["System.Description"] or "",
  }
end

local function edit_field_order_for_item(item)
  local order = {}
  for _, key in ipairs(EDIT_BASE_FIELD_ORDER) do
    table.insert(order, key)
  end
  if is_task_item(item) then
    for _, key in ipairs(EDIT_TASK_FIELD_ORDER) do
      table.insert(order, key)
    end
  end
  return order
end

local function active_edit_fields(item)
  local fields = {}
  for _, key in ipairs(edit_field_order_for_item(item)) do
    table.insert(fields, EDIT_FIELD_DEFINITIONS[key])
  end
  table.insert(fields, EDIT_FIELD_DEFINITIONS.description)
  return fields
end

local function build_edit_layout(item)
  local order = edit_field_order_for_item(item)
  local fields = {}
  for index, key in ipairs(order) do
    local definition = EDIT_FIELD_DEFINITIONS[key]
    local label = definition.edit_label
    fields[key] = {
      key = key,
      line = index - 1,
      label = label,
      value_col = #label,
      padding = string.rep(" ", #label),
    }
  end
  return {
    fields = fields,
    order = order,
    description_label_line = #order,
    description_start_line = #order + 1,
  }
end

local function edit_layout_for_bufnr(bufnr)
  local meta = vim.b[bufnr].taskmeister_edit_meta
  return build_edit_layout(meta and meta.original or nil)
end

local function parse_decimal_hours(value, field)
  local raw = trim(value)
  if raw == "" then
    return nil, nil
  end
  if not (raw:match("^%d+$") or raw:match("^%d+%.%d+$")) then
    return nil, field.label .. " must be a non-negative decimal hour value"
  end
  local number = tonumber(raw)
  if not number or number < 0 then
    return nil, field.label .. " must be a non-negative decimal hour value"
  end
  return number, nil
end

local function field_values_equal(field, left, right)
  if field.numeric then
    local left_number, left_err = parse_decimal_hours(left, field)
    local right_number, right_err = parse_decimal_hours(right, field)
    if left_err or right_err then
      return trim(left) == trim(right)
    end
    return left_number == right_number
  end
  return (left or "") == (right or "")
end

local function extract_labeled_value(value, layout)
  value = tostring(value or "")
  if value:sub(1, layout.value_col) == layout.padding then
    return value:sub(layout.value_col + 1)
  end
  if value:sub(1, #layout.label) == layout.label then
    return value:sub(layout.value_col + 1)
  end
  local leading_spaces = value:match("^%s*") or ""
  if #leading_spaces > 0 and #leading_spaces < layout.value_col then
    return value:sub(#leading_spaces + 1)
  end
  if #value >= layout.value_col then
    return value:sub(layout.value_col + 1)
  end
  return ""
end

local function labeled_edit_line(layout, value)
  return layout.padding .. tostring(value or "")
end

local function normalize_labeled_line(bufnr, key)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local layout = edit_layout_for_bufnr(bufnr).fields[key]
  if not layout then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, layout.line, layout.line + 1, false)[1]
  if line == nil then
    return nil
  end
  if line:sub(1, layout.value_col) == layout.padding then
    return line
  end

  local fixed = labeled_edit_line(layout, extract_labeled_value(line, layout))
  vim.api.nvim_buf_set_lines(bufnr, layout.line, layout.line + 1, false, { fixed })
  return fixed
end

local function extract_editor_values(bufnr)
  local layout_info = edit_layout_for_bufnr(bufnr)
  local values = {}
  for _, key in ipairs(layout_info.order) do
    local layout = layout_info.fields[key]
    values[key] = extract_labeled_value(normalize_labeled_line(bufnr, key), layout)
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local description_lines = {}
  for i = layout_info.description_start_line + 1, #lines do
    if lines[i] == COMMENTS_MARKER then
      break
    end
    table.insert(description_lines, lines[i])
  end
  while #description_lines > 0 and description_lines[#description_lines] == "" do
    table.remove(description_lines, #description_lines)
  end
  values.description = table.concat(description_lines, "\n")
  return values
end

local function changed_fields_from_editor(meta, values)
  local changed_fields = {}
  local changed_keys = {}
  if not meta or not meta.original or not values then
    return changed_fields, changed_keys
  end

  local original = editor_values_from_item(meta.original)
  for _, field in ipairs(active_edit_fields(meta.original)) do
    if not field_values_equal(field, values[field.key], original[field.key]) then
      table.insert(changed_fields, field)
      changed_keys[field.key] = true
    end
  end

  return changed_fields, changed_keys
end

local function current_save_status(bufnr, rev)
  local status = vim.b[bufnr].taskmeister_save_status or "idle"
  if status == "dirty" then
    return "Unsaved changes", "WarningMsg"
  end
  if status == "clean" or status == "idle" then
    return "No changes", "Comment"
  end
  if status == "saving" then
    return "Saving changes...", "TaskmeisterBlue"
  end
  if status == "saved" then
    return string.format("Saved (rev %s)", tostring(rev)), "TaskmeisterBlue"
  end
  if status == "saved_dirty" then
    return string.format("Saved (rev %s); unsaved edits remain", tostring(rev)), "WarningMsg"
  end
  if status == "invalid" then
    return vim.b[bufnr].taskmeister_save_error or "Invalid field value", "ErrorMsg"
  end
  if status == "error" then
    return "Save failed", "ErrorMsg"
  end
  return "", "Normal"
end

local function build_patches_from_editor(meta, values)
  local patches = {}
  local original = editor_values_from_item(meta.original)
  local changed_fields = changed_fields_from_editor(meta, values)
  for _, field in ipairs(changed_fields) do
    if field.numeric then
      local number, validation_err = parse_decimal_hours(values[field.key], field)
      if validation_err then
        return nil, validation_err
      end
      if number == nil then
        table.insert(patches, { op = "remove", path = field.path })
      else
        local op = trim(original[field.key]) == "" and "add" or "replace"
        table.insert(patches, { op = op, path = field.path, value = number })
      end
    else
      table.insert(patches, { op = "replace", path = field.path, value = values[field.key] })
    end
  end
  return patches, nil
end

local function editor_values_equal(left, right)
  left = left or {}
  right = right or {}
  for _, field in pairs(EDIT_FIELD_DEFINITIONS) do
    if (left[field.key] or "") ~= (right[field.key] or "") then
      return false
    end
  end
  return true
end

local function get_cached_comments(bufnr)
  return vim.b[bufnr].taskmeister_edit_comments or {}
end

local function refresh_edit_field_labels(bufnr, changed_keys)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  changed_keys = changed_keys or {}
  local layout_info = edit_layout_for_bufnr(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, edit_label_ns, 0, -1)

  local function label_hl(key)
    return changed_keys[key] and "TaskmeisterChangedField" or "TaskmeisterBlue"
  end

  for _, key in ipairs(layout_info.order) do
    if key ~= "tags" then
      local layout = layout_info.fields[key]
      vim.api.nvim_buf_set_extmark(bufnr, edit_label_ns, layout.line, 0, {
        virt_text = { { layout.label, label_hl(key) } },
        virt_text_pos = "overlay",
      })
    end
  end
  vim.api.nvim_buf_set_extmark(bufnr, edit_label_ns, layout_info.description_label_line, 0, {
    virt_text = { { "Description:", label_hl("description") } },
    virt_text_pos = "inline",
  })
end

local function refresh_edit_tag_badges(bufnr, changed_keys)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  changed_keys = changed_keys or {}
  local layout = edit_layout_for_bufnr(bufnr).fields.tags
  if not layout then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, edit_tag_ns, 0, -1)
  local tag_line = vim.api.nvim_buf_get_lines(bufnr, layout.line, layout.line + 1, false)[1]
  if tag_line == nil then
    return
  end
  local prefix_hl = changed_keys.tags and "TaskmeisterChangedField" or "TaskmeisterBlue"
  vim.api.nvim_buf_set_extmark(bufnr, edit_tag_ns, layout.line, 0, {
    virt_text = { { layout.label, prefix_hl } },
    virt_text_pos = "overlay",
  })
  badges.decorate_tag_field(bufnr, edit_tag_ns, layout.line, tag_line, layout.value_col)
end

local function render_edit_status(bufnr, item, values)
  local save_status_text, save_status_hl = current_save_status(bufnr, item.rev)
  local fields = item.fields or {}
  local tag_value = values and values.tags or fields["System.Tags"] or ""
  local changed_fields = changed_fields_from_editor(vim.b[bufnr].taskmeister_edit_meta, values)
  local virt_lines = {
    { { string.format("Work Item #%s • rev %s", tostring(item.id), tostring(item.rev)), "TaskmeisterBlue" } },
  }
  local tag_chunks = badges.tag_chunks(tag_value)
  if #tag_chunks > 0 then
    local line = { { "Labels: ", "TaskmeisterBlue" } }
    vim.list_extend(line, tag_chunks)
    table.insert(virt_lines, line)
  end
  if #changed_fields > 0 then
    local labels = {}
    for _, field in ipairs(changed_fields) do
      table.insert(labels, field.label)
    end
    table.insert(virt_lines, {
      { "Changed: ", "TaskmeisterChangedField" },
      { table.concat(labels, ", "), "TaskmeisterChangedField" },
    })
  end
  table.insert(virt_lines, { { save_status_text, save_status_hl } })
  table.insert(virt_lines, { { "Save: :w / <C-s>   Add comment: <leader>wc   React: <leader>wr   Close: q", "Comment" } })
  table.insert(virt_lines, { { "", "Normal" } })

  vim.api.nvim_buf_clear_namespace(bufnr, status_ns, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, status_ns, 0, 0, {
    virt_lines = virt_lines,
    virt_lines_above = true,
  })
end

local function refresh_edit_save_status(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].taskmeister_rendering_edit_dialog then
    return
  end
  local meta = vim.b[bufnr].taskmeister_edit_meta
  if not meta or not meta.original then
    return
  end
  local values = extract_editor_values(bufnr)
  local _, changed_keys = changed_fields_from_editor(meta, values)
  refresh_edit_field_labels(bufnr, changed_keys)
  refresh_edit_tag_badges(bufnr, changed_keys)
  if vim.b[bufnr].taskmeister_save_in_progress then
    vim.b[bufnr].taskmeister_save_status = "saving"
    render_edit_status(bufnr, meta.original, values)
    return
  end

  local patches, validation_err = build_patches_from_editor(meta, values)
  if validation_err then
    vim.b[bufnr].taskmeister_save_status = "invalid"
    vim.b[bufnr].taskmeister_save_error = validation_err
    render_edit_status(bufnr, meta.original, values)
    return
  end
  vim.b[bufnr].taskmeister_save_error = nil
  if vim.tbl_isempty(patches) then
    if vim.b[bufnr].taskmeister_save_status ~= "saved" then
      vim.b[bufnr].taskmeister_save_status = "clean"
    end
  else
    vim.b[bufnr].taskmeister_save_status = "dirty"
  end
  render_edit_status(bufnr, meta.original, values)
end

local function get_comments_with_reactions_async(work_item_id, callback)
  api.get_work_item_comments_async(work_item_id, function(fetched_comments, err)
    if err then
      callback(nil, err)
      return
    end
    local comments = {}
    for _, comment in ipairs(fetched_comments or {}) do
      if comment.id and comment.text and comment.text ~= "" then
        table.insert(comments, {
          id = comment.id,
          user = comment.created_by or "System",
          timestamp = comment.created_date or "",
          value = comment.text,
          reactions = comment.reactions or {},
        })
      end
    end
    callback(comments, nil)
  end)
end

local function render_loading(bufnr, id)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "Loading work item #" .. tostring(id) .. "...",
    "",
    "Please wait",
  })
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
end

local function reaction_badges(reactions)
  local icons = (config.options.ui and config.options.ui.icons) or {}
  return badges.reaction_chunks(reactions, icons)
end

local function render_edit_dialog(bufnr, item, comments)
  comments = comments or {}
  vim.b[bufnr].taskmeister_edit_comments = comments
  vim.b[bufnr].taskmeister_rendering_edit_dialog = true
  local values = editor_values_from_item(item)
  local layout_info = build_edit_layout(item)
  local description_lines = split_text(values.description)
  local lines = {}
  for _, key in ipairs(layout_info.order) do
    table.insert(lines, labeled_edit_line(layout_info.fields[key], values[key]))
  end
  table.insert(lines, "")
  vim.list_extend(lines, description_lines)
  table.insert(lines, "")
  table.insert(lines, COMMENTS_MARKER)
  local comments_start = #lines + 1
  local comment_rows = {}
  if #comments > 0 then
    for _, comment in ipairs(comments) do
      table.insert(lines, string.format("[#%d] %s  %s", comment.id, comment.user, comment.timestamp))
      table.insert(comment_rows, {
        line = #lines - 1,
        col = #(lines[#lines]),
        reactions = comment.reactions or {},
      })
      for _, text_line in ipairs(split_text(comment.value)) do
        table.insert(lines, "  " .. text_line)
      end
      table.insert(lines, "")
    end
  else
    table.insert(lines, "No comments yet.")
  end

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, edit_ns, 0, -1)
  local _, changed_keys = changed_fields_from_editor(vim.b[bufnr].taskmeister_edit_meta, values)
  render_edit_status(bufnr, item, values)
  refresh_edit_field_labels(bufnr, changed_keys)
  refresh_edit_tag_badges(bufnr, changed_keys)
  vim.api.nvim_buf_add_highlight(bufnr, edit_ns, "TaskmeisterBlue", comments_start - 1, 0, -1)

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for i = comments_start, line_count do
    local line = (vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or "")
    if line:match("^%[#%d+%]") then
      vim.api.nvim_buf_add_highlight(bufnr, edit_ns, "TaskmeisterComment", i - 1, 0, -1)
    end
  end

  for _, row in ipairs(comment_rows) do
    local chunks = reaction_badges(row.reactions)
    if #chunks > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, edit_ns, row.line, row.col, {
        virt_text = chunks,
        virt_text_pos = "inline",
      })
    end
  end

  vim.api.nvim_buf_set_option(bufnr, "modified", false)
  vim.b[bufnr].taskmeister_rendering_edit_dialog = false
end

local function edit_dialog_has_changes(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local meta = vim.b[bufnr].taskmeister_edit_meta
  if not meta or not meta.original then
    return vim.bo[bufnr].modified
  end
  local patches, validation_err = build_patches_from_editor(meta, extract_editor_values(bufnr))
  return validation_err ~= nil or not vim.tbl_isempty(patches or {})
end

local function field_at_cursor(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local layout_info = edit_layout_for_bufnr(bufnr)
  for _, key in ipairs(layout_info.order) do
    local layout = layout_info.fields[key]
    if cursor[1] == layout.line + 1 then
      return key, layout, cursor
    end
  end
  return nil, nil, cursor
end

local function clamp_edit_field_cursor(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end

  local key, layout, cursor = field_at_cursor(bufnr)
  if not key then
    return
  end

  normalize_labeled_line(bufnr, key)

  if cursor[2] < layout.value_col then
    vim.api.nvim_win_set_cursor(0, { cursor[1], layout.value_col })
  end
end

local function start_insert_after_field_label(bufnr, force_field_start)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
    return false
  end

  local key, layout, cursor = field_at_cursor(bufnr)
  if not key then
    return false
  end

  normalize_labeled_line(bufnr, key)
  if force_field_start or cursor[2] < layout.value_col then
    vim.api.nvim_win_set_cursor(0, { cursor[1], layout.value_col })
    vim.cmd("startinsert")
    return true
  end

  return false
end

local function feed_normal_key(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
end

local function close_edit_dialog(bufnr, win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  if vim.b[bufnr].taskmeister_save_in_progress then
    vim.notify("Save already in progress", vim.log.levels.INFO)
    return
  end

  if not edit_dialog_has_changes(bufnr) then
    vim.api.nvim_win_close(win, true)
    return
  end

  vim.ui.select({ "Cancel", "Discard changes" }, {
    prompt = "Discard unsaved Taskmeister changes?",
  }, function(choice)
    if choice == "Discard changes" and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end)
end

function M.open_work_item(id)
  id = tonumber(id)
  if not id then
    vim.notify("Invalid work item ID", vim.log.levels.ERROR)
    return
  end
  local items = api.get_work_items_batch({ id })
  local item = items[1]
  if not item then
    vim.notify("Work item not found: " .. id, vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "taskmeister://workitem/" .. id)
  vim.b[bufnr].taskmeister_work_item_id = id -- Set for keymaps
  buffer.render_work_item(bufnr, item)
  vim.api.nvim_buf_set_option(bufnr, "filetype", "taskmeister")
  vim.api.nvim_buf_set_option(bufnr, "buftype", "acwrite")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  if config.options.ui and config.options.ui.use_signcolumn then
    vim.api.nvim_buf_set_option(bufnr, "signcolumn", "yes:1")
  end
  vim.api.nvim_set_current_buf(bufnr)
end

function M.save_work_item_dialog(bufnr)
  M.save_work_item_dialog_async(bufnr, nil)
end

local function notify_save_failure(meta, err)
  if err and err.is_conflict then
    vim.notify(
      "Work item #" .. meta.id .. " was updated remotely since revision " .. tostring(meta.rev) .. ". Reload and retry.",
      vim.log.levels.WARN
    )
    return
  end
  vim.notify("Failed to save work item #" .. meta.id .. ": " .. (err and err.message or "unknown error"), vim.log.levels.ERROR)
end

function M.save_work_item_dialog_sync(bufnr)
  local meta = vim.b[bufnr].taskmeister_edit_meta
  if not meta or not meta.id then
    vim.notify("No edit metadata found for this buffer", vim.log.levels.ERROR)
    return false
  end

  if vim.b[bufnr].taskmeister_save_in_progress then
    vim.notify("Save already in progress", vim.log.levels.INFO)
    return false
  end

  local values = extract_editor_values(bufnr)
  local patches, validation_err = build_patches_from_editor(meta, values)
  if validation_err then
    vim.b[bufnr].taskmeister_save_status = "invalid"
    vim.b[bufnr].taskmeister_save_error = validation_err
    render_edit_status(bufnr, meta.original, values)
    vim.notify(validation_err, vim.log.levels.ERROR)
    return false
  end

  if vim.tbl_isempty(patches) then
    vim.api.nvim_buf_set_option(bufnr, "modified", false)
    vim.b[bufnr].taskmeister_save_status = "saved"
    vim.b[bufnr].taskmeister_save_error = nil
    render_edit_dialog(bufnr, meta.original, get_cached_comments(bufnr))
    vim.notify("No changes to save for work item #" .. meta.id, vim.log.levels.INFO)
    return true
  end

  vim.b[bufnr].taskmeister_save_in_progress = true
  vim.b[bufnr].taskmeister_save_status = "saving"
  vim.b[bufnr].taskmeister_save_error = nil
  render_edit_status(bufnr, meta.original, values)
  vim.notify("Saving work item #" .. meta.id .. "...", vim.log.levels.INFO)

  local updated, err = api.update_work_item_checked(meta.id, patches, meta.rev)
  vim.b[bufnr].taskmeister_save_in_progress = false

  if not updated then
    vim.b[bufnr].taskmeister_save_status = "error"
    render_edit_status(bufnr, meta.original, values)
    notify_save_failure(meta, err)
    return false
  end

  vim.b[bufnr].taskmeister_edit_meta = {
    id = updated.id,
    rev = updated.rev,
    original = updated,
  }
  vim.b[bufnr].taskmeister_save_status = "saved"
  render_edit_dialog(bufnr, updated, get_cached_comments(bufnr))
  vim.notify("Saved work item #" .. meta.id .. " at revision " .. tostring(updated.rev), vim.log.levels.INFO)
  return true
end

function M.save_work_item_dialog_async(bufnr, callback)
  local meta = vim.b[bufnr].taskmeister_edit_meta
  if not meta or not meta.id then
    vim.notify("No edit metadata found for this buffer", vim.log.levels.ERROR)
    if callback then
      callback(false)
    end
    return
  end

  if vim.b[bufnr].taskmeister_save_in_progress then
    vim.notify("Save already in progress", vim.log.levels.INFO)
    if callback then
      callback(false)
    end
    return
  end

  local values = extract_editor_values(bufnr)
  local patches, validation_err = build_patches_from_editor(meta, values)
  if validation_err then
    vim.b[bufnr].taskmeister_save_status = "invalid"
    vim.b[bufnr].taskmeister_save_error = validation_err
    render_edit_status(bufnr, meta.original, values)
    vim.notify(validation_err, vim.log.levels.ERROR)
    if callback then
      callback(false)
    end
    return
  end

  if vim.tbl_isempty(patches) then
    vim.api.nvim_buf_set_option(bufnr, "modified", false)
    vim.b[bufnr].taskmeister_save_status = "saved"
    vim.b[bufnr].taskmeister_save_error = nil
    render_edit_dialog(bufnr, meta.original, get_cached_comments(bufnr))
    vim.notify("No changes to save for work item #" .. meta.id, vim.log.levels.INFO)
    if callback then
      callback(true)
    end
    return
  end

  vim.b[bufnr].taskmeister_save_in_progress = true
  vim.b[bufnr].taskmeister_save_status = "saving"
  vim.b[bufnr].taskmeister_save_error = nil
  render_edit_status(bufnr, meta.original, values)
  vim.notify("Saving work item #" .. meta.id .. "...", vim.log.levels.INFO)

  api.update_work_item_checked_async(meta.id, patches, meta.rev, function(updated, err)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      vim.b[bufnr].taskmeister_save_in_progress = false

      if not updated then
        vim.b[bufnr].taskmeister_save_status = "error"
        render_edit_status(bufnr, meta.original, values)
        notify_save_failure(meta, err)
        if callback then
          callback(false)
        end
        return
      end

      vim.b[bufnr].taskmeister_edit_meta = {
        id = updated.id,
        rev = updated.rev,
        original = updated,
      }
      vim.b[bufnr].taskmeister_save_status = "saved"
      local current_values = extract_editor_values(bufnr)
      if not editor_values_equal(current_values, values) then
        vim.b[bufnr].taskmeister_save_status = "saved_dirty"
        render_edit_status(bufnr, updated, current_values)
        vim.notify(
          "Saved work item #" .. meta.id .. " at revision " .. tostring(updated.rev) .. "; local edits remain unsaved",
          vim.log.levels.WARN
        )
        if callback then
          callback(false)
        end
        return
      end

      render_edit_dialog(bufnr, updated, get_cached_comments(bufnr))
      vim.notify("Saved work item #" .. meta.id .. " at revision " .. tostring(updated.rev), vim.log.levels.INFO)

      if callback then
        callback(true)
      end

      get_comments_with_reactions_async(meta.id, function(comments, comments_err)
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(bufnr) then
            return
          end
          local latest_meta = vim.b[bufnr].taskmeister_edit_meta
          local latest_item = (latest_meta and latest_meta.original) or updated
          if comments_err then
            vim.notify("Failed to refresh comments: " .. comments_err, vim.log.levels.WARN)
            return
          end
          if vim.bo[bufnr].modified then
            vim.b[bufnr].taskmeister_edit_comments = comments or {}
            return
          end
          render_edit_dialog(bufnr, latest_item, comments or {})
        end)
      end)
      return
    end)
  end)
end

function M.add_comment_to_dialog(bufnr)
  if vim.b[bufnr].taskmeister_save_in_progress then
    vim.notify("Save already in progress", vim.log.levels.INFO)
    return
  end

  local function continue_add_comment()
    local meta = vim.b[bufnr].taskmeister_edit_meta
    if not meta or not meta.id then
      vim.notify("No edit metadata found for this buffer", vim.log.levels.ERROR)
      return
    end
    local comment = vim.fn.input("Comment: ")
    if comment == "" then
      return
    end

    api.add_work_item_comment_async(meta.id, comment, function(_, err)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        if err then
          vim.notify("Failed to add comment: " .. (err or "unknown error"), vim.log.levels.ERROR)
          return
        end

        api.get_work_items_batch_async({ meta.id }, function(items)
          vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(bufnr) then
              return
            end
            local updated = (items and items[1]) or meta.original
            vim.b[bufnr].taskmeister_edit_meta = {
              id = updated.id,
              rev = updated.rev,
              original = updated,
            }
            get_comments_with_reactions_async(meta.id, function(comments)
              vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then
                  return
                end
                render_edit_dialog(bufnr, updated, comments or {})
                vim.notify("Added comment to work item #" .. meta.id, vim.log.levels.INFO)
              end)
            end)
          end)
        end, EDIT_DIALOG_FIELDS)
      end)
    end)
  end

  if vim.bo[bufnr].modified then
    M.save_work_item_dialog_async(bufnr, function(saved)
      if not saved then
        vim.notify("Could not save pending edits, comment not added", vim.log.levels.WARN)
        return
      end
      continue_add_comment()
    end)
    return
  end
  continue_add_comment()
end

function M.react_to_comment_in_dialog(bufnr)
  if vim.b[bufnr].taskmeister_save_in_progress then
    vim.notify("Save already in progress", vim.log.levels.INFO)
    return
  end

  local function continue_react_to_comment()
    local meta = vim.b[bufnr].taskmeister_edit_meta
    if not meta or not meta.id then
      vim.notify("No edit metadata found for this buffer", vim.log.levels.ERROR)
      return
    end

    get_comments_with_reactions_async(meta.id, function(comments, comments_err)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        if comments_err then
          vim.notify("Failed to fetch comments: " .. comments_err, vim.log.levels.ERROR)
          return
        end
        if not comments or #comments == 0 then
          vim.notify("No comments available for reactions", vim.log.levels.INFO)
          return
        end

        vim.ui.select(comments, {
          prompt = "Select comment to react to",
          format_item = function(comment)
            local first = split_text(comment.value)[1] or ""
            return string.format("#%d %s: %s", comment.id, comment.user, first)
          end,
        }, function(selected_comment)
          if not selected_comment then
            return
          end

          vim.ui.select(REACTION_TYPES, {
            prompt = "Select reaction",
            format_item = function(reaction)
              local icons = (config.options.ui and config.options.ui.icons) or {}
              return string.format("%s %s", badges.reaction_icon(reaction, icons), reaction)
            end,
          }, function(reaction)
            if not reaction then
              return
            end

            local comment_id = selected_comment.id
            local before_count = tonumber((selected_comment.reactions or {})[reaction]) or 0

            local function on_toggled(action, ok, err)
              vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then
                  return
                end
                if not ok then
                  vim.notify("Failed to toggle reaction: " .. (err or "unknown error"), vim.log.levels.ERROR)
                  return
                end
                api.get_work_items_batch_async({ meta.id }, function(items)
                  vim.schedule(function()
                    if not vim.api.nvim_buf_is_valid(bufnr) then
                      return
                    end
                    local latest = (items and items[1]) or meta.original
                    vim.b[bufnr].taskmeister_edit_meta = {
                      id = latest.id or meta.id,
                      rev = latest.rev or meta.rev,
                      original = latest,
                    }
                    get_comments_with_reactions_async(meta.id, function(updated_comments)
                      vim.schedule(function()
                        if not vim.api.nvim_buf_is_valid(bufnr) then
                          return
                        end
                        render_edit_dialog(bufnr, latest, updated_comments or {})
                        vim.notify("Reaction " .. action .. " on comment #" .. comment_id, vim.log.levels.INFO)
                      end)
                    end)
                  end)
                end, EDIT_DIALOG_FIELDS)
              end)
            end

            api.add_comment_reaction_async(meta.id, comment_id, reaction, function(added_ok, add_err)
              if not added_ok then
                on_toggled("added", false, add_err)
                return
              end
              api.get_comment_reactions_async(meta.id, comment_id, function(after_reactions)
                local after_count = tonumber((after_reactions or {})[reaction]) or 0
                if after_count > before_count then
                  on_toggled("added", true, nil)
                  return
                end
                api.remove_comment_reaction_async(meta.id, comment_id, reaction, function(removed_ok, remove_err)
                  on_toggled("removed", removed_ok, remove_err)
                end)
              end)
            end)
          end)
        end)
      end)
    end)
  end

  if vim.bo[bufnr].modified then
    M.save_work_item_dialog_async(bufnr, function(saved)
      if not saved then
        vim.notify("Could not save pending edits, reaction not added", vim.log.levels.WARN)
        return
      end
      continue_react_to_comment()
    end)
    return
  end
  continue_react_to_comment()
end

function M.open_work_item_edit_dialog(id)
  id = parse_work_item_id(id)
  if not id then
    vim.notify("Invalid work item ID", vim.log.levels.ERROR)
    return
  end

  local width = math.floor(vim.o.columns * 0.7)
  local height = math.max(12, math.floor(vim.o.lines * 0.6))
  local row = math.floor((vim.o.lines - height) / 2 - 1)
  local col = math.floor((vim.o.columns - width) / 2)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "taskmeister://edit/" .. id)
  vim.api.nvim_buf_set_option(bufnr, "buftype", "acwrite")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
  vim.api.nvim_buf_set_option(bufnr, "filetype", "taskmeister_edit")
  render_loading(bufnr, id)

  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = row,
    col = col,
    title = " Edit Work Item #" .. id .. " ",
    title_pos = "center",
  })
  pcall(vim.api.nvim_win_set_option, win, "virtualedit", "onemore")

  vim.keymap.set("n", "q", function()
    close_edit_dialog(bufnr, win)
  end, { buffer = bufnr, silent = true, desc = "Close edit dialog" })
  vim.keymap.set("n", "i", function()
    if not start_insert_after_field_label(bufnr, false) then
      feed_normal_key("i")
    end
  end, { buffer = bufnr, silent = true, desc = "Insert after field label" })
  vim.keymap.set("n", "a", function()
    if not start_insert_after_field_label(bufnr, false) then
      feed_normal_key("a")
    end
  end, { buffer = bufnr, silent = true, desc = "Append after field label" })
  vim.keymap.set("n", "I", function()
    if not start_insert_after_field_label(bufnr, true) then
      feed_normal_key("I")
    end
  end, { buffer = bufnr, silent = true, desc = "Insert at field value start" })
  vim.keymap.set("n", "<C-s>", function()
    M.save_work_item_dialog(bufnr)
  end, { buffer = bufnr, silent = true, desc = "Save work item" })
  vim.keymap.set("n", "<leader>ws", function()
    M.save_work_item_dialog(bufnr)
  end, { buffer = bufnr, silent = true, desc = "Save work item" })
  vim.keymap.set("n", "<leader>wc", function()
    M.add_comment_to_dialog(bufnr)
  end, { buffer = bufnr, silent = true, desc = "Add comment" })
  vim.keymap.set("n", "gc", function()
    M.add_comment_to_dialog(bufnr)
  end, { buffer = bufnr, silent = true, desc = "Add comment" })
  vim.keymap.set("n", "<leader>wr", function()
    M.react_to_comment_in_dialog(bufnr)
  end, { buffer = bufnr, silent = true, desc = "React to comment" })
  vim.keymap.set("n", "gr", function()
    M.react_to_comment_in_dialog(bufnr)
  end, { buffer = bufnr, silent = true, desc = "React to comment" })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      M.save_work_item_dialog_sync(bufnr)
    end,
    desc = "Save Taskmeister work item edit dialog",
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave", "BufModifiedSet" }, {
    buffer = bufnr,
    callback = function()
      refresh_edit_save_status(bufnr)
    end,
    desc = "Refresh Taskmeister edit dialog save status",
  })
  vim.api.nvim_create_autocmd({ "InsertEnter", "CursorMovedI" }, {
    buffer = bufnr,
    callback = function()
      clamp_edit_field_cursor(bufnr)
    end,
    desc = "Keep Taskmeister edit field cursor after label",
  })

  api.get_work_items_batch_async({ id }, function(items, err)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      if err then
        vim.notify("Failed to fetch work item #" .. id .. ": " .. err, vim.log.levels.ERROR)
        return
      end
      local item = items and items[1] or nil
      if not item then
        vim.notify("Work item not found: " .. id, vim.log.levels.ERROR)
        return
      end
      vim.b[bufnr].taskmeister_edit_meta = {
        id = id,
        rev = item.rev,
        original = item,
      }
      get_comments_with_reactions_async(id, function(comments, comments_err)
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(bufnr) then
            return
          end
          if comments_err then
            vim.notify("Failed to fetch comments: " .. comments_err, vim.log.levels.WARN)
            comments = {}
          end
          render_edit_dialog(bufnr, item, comments or {})
        end)
      end)
    end)
  end, EDIT_DIALOG_FIELDS)

end

function M.create_work_item(type)
  local valid_types = { "Task", "Bug", "Feature", "User Story" }
  if not vim.tbl_contains(valid_types, type) then
    vim.notify("Invalid work item type: " .. type, vim.log.levels.ERROR)
    return
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "taskmeister://new/" .. type)
  buffer.render_work_item(bufnr, { type = type }, true)
  vim.api.nvim_buf_set_option(bufnr, "filetype", "taskmeister")
  vim.api.nvim_buf_set_option(bufnr, "buftype", "acwrite")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  if config.options.ui and config.options.ui.use_signcolumn then
    vim.api.nvim_buf_set_option(bufnr, "signcolumn", "yes:1")
  end
  vim.api.nvim_set_current_buf(bufnr)
end

function M.sync_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local id = name:match("taskmeister://workitem/(%d+)")
  local is_new = name:match("taskmeister://new/(.+)")
  local item = id and api.get_work_items_batch({ tonumber(id) })[1] or { fields = {}, type = is_new }
  local changes = buffer.parse_changes(lines, item)
  local patches = {}
  if changes.title and changes.title ~= (item.fields and item.fields["System.Title"] or "") then
    table.insert(patches, { op = "replace", path = "/fields/System.Title", value = changes.title })
  end
  if changes.description and changes.description ~= (item.fields and item.fields["System.Description"] or "") then
    table.insert(patches, { op = "replace", path = "/fields/System.Description", value = changes.description })
  end
  if changes.state and changes.state ~= (item.fields and item.fields["System.State"] or "New") then
    table.insert(patches, { op = "replace", path = "/fields/System.State", value = changes.state })
  end
  if changes.assigned_to and changes.assigned_to ~= (item.fields and item.fields["System.AssignedTo"] and item.fields["System.AssignedTo"].uniqueName or "") then
    table.insert(patches, { op = "replace", path = "/fields/System.AssignedTo", value = changes.assigned_to })
  end
  if changes.tags ~= (item.fields and item.fields["System.Tags"] or "") then
    table.insert(patches, { op = "replace", path = "/fields/System.Tags", value = changes.tags or "" })
  end
  if not vim.tbl_isempty(patches) then
    if is_new then
      local new_item = api.create_work_item(item.type, patches)
      vim.api.nvim_buf_set_name(bufnr, "taskmeister://workitem/" .. new_item.id)
      vim.b[bufnr].taskmeister_work_item_id = new_item.id
      vim.notify("Created work item #" .. new_item.id)
    else
      api.update_work_item(tonumber(id), patches)
      vim.notify("Updated work item #" .. id)
    end
    M.open_work_item(id or new_item.id)
  end
end

return M
