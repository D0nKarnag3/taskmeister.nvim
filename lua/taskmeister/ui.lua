local api = require("taskmeister.api")
local buffer = require("taskmeister.buffer")
local config = require("taskmeister.config")

local M = {}

local buffers = {}  -- Track open work items by ID
local edit_ns = vim.api.nvim_create_namespace("taskmeister_edit")
local COMMENTS_MARKER = "──────────────── Comments ────────────────"
local REACTION_TYPES = {
  "like",
  "dislike",
  "heart",
  "hooray",
  "laugh",
  "confused",
}
local REACTION_ICONS = {
  like = "👍",
  dislike = "👎",
  heart = "❤️",
  hooray = "🎉",
  laugh = "😄",
  confused = "😕",
}

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

local function extract_editor_values(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local title = lines[1] or ""
  local state = lines[2] or ""
  local assigned = lines[3] or ""
  local description_lines = {}
  for i = 5, #lines do
    if lines[i] == COMMENTS_MARKER then
      break
    end
    table.insert(description_lines, lines[i])
  end
  while #description_lines > 0 and description_lines[#description_lines] == "" do
    table.remove(description_lines, #description_lines)
  end
  return {
    title = title,
    state = state,
    assigned_to = assigned,
    description = table.concat(description_lines, "\n"),
  }
end

local function get_comments_with_reactions(work_item_id)
  local comments = {}
  local fetched_comments = api.get_work_item_comments(work_item_id)
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
  return comments
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

local function reaction_bubbles(reactions)
  local icons = (config.options.ui and config.options.ui.icons) or {}
  local delimiter = (config.options.ui and config.options.ui.bubble_delimiter) or "│"
  local chunks = {}
  for _, reaction in ipairs(REACTION_TYPES) do
    local count = reactions[reaction]
    if count and count > 0 then
      local icon = icons[reaction] or REACTION_ICONS[reaction] or reaction
      table.insert(chunks, { string.format(" %s%s %d%s", delimiter, icon, count, delimiter), "TaskmeisterBlue" })
    end
  end
  return chunks
end

local function render_edit_dialog(bufnr, item, comments)
  local fields = item.fields or {}
  local title = fields["System.Title"] or ""
  local state = fields["System.State"] or "New"
  local assigned_to = fields["System.AssignedTo"]
  local assigned = ""
  if type(assigned_to) == "table" then
    assigned = assigned_to.uniqueName or assigned_to.displayName or ""
  elseif type(assigned_to) == "string" then
    assigned = assigned_to
  end
  local description_lines = split_text(fields["System.Description"] or "")
  local lines = {
    title,
    state,
    assigned,
    "",
  }
  vim.list_extend(lines, description_lines)
  table.insert(lines, "")
  table.insert(lines, COMMENTS_MARKER)
  local comments_start = #lines + 1
  local comment_rows = {}
  if comments and #comments > 0 then
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
  vim.api.nvim_buf_set_extmark(bufnr, edit_ns, 0, 0, {
    virt_lines = {
      { { string.format("Work Item #%s • rev %s", tostring(item.id), tostring(item.rev)), "TaskmeisterBlue" } },
      { { "Save: :w / <C-s>   Add comment: <leader>wc   React: <leader>wr   Close: q", "Comment" } },
      { { "", "Normal" } },
    },
    virt_lines_above = true,
  })
  vim.api.nvim_buf_set_extmark(bufnr, edit_ns, 0, 0, {
    virt_text = { { "Title: ", "TaskmeisterBlue" } },
    virt_text_pos = "inline",
  })
  vim.api.nvim_buf_set_extmark(bufnr, edit_ns, 1, 0, {
    virt_text = { { "State: ", "TaskmeisterBlue" } },
    virt_text_pos = "inline",
  })
  vim.api.nvim_buf_set_extmark(bufnr, edit_ns, 2, 0, {
    virt_text = { { "Assigned To: ", "TaskmeisterBlue" } },
    virt_text_pos = "inline",
  })
  vim.api.nvim_buf_set_extmark(bufnr, edit_ns, 3, 0, {
    virt_text = { { "Description:", "TaskmeisterBlue" } },
    virt_text_pos = "eol",
  })
  vim.api.nvim_buf_add_highlight(bufnr, edit_ns, "TaskmeisterBlue", comments_start - 1, 0, -1)

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for i = comments_start + 1, line_count do
    local line = (vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or "")
    if line:match("^%[#%d+%]") then
      vim.api.nvim_buf_add_highlight(bufnr, edit_ns, "TaskmeisterComment", i - 1, 0, -1)
    end
  end

  for _, row in ipairs(comment_rows) do
    local bubbles = reaction_bubbles(row.reactions)
    if #bubbles > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, edit_ns, row.line, row.col, {
        virt_text = bubbles,
        virt_text_pos = "inline",
      })
    end
  end

  vim.api.nvim_buf_set_option(bufnr, "modified", false)
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
  if config.ui and config.ui.use_signcolumn then
    vim.api.nvim_buf_set_option(bufnr, "signcolumn", "yes:1")
  end
  vim.api.nvim_set_current_buf(bufnr)
end

function M.save_work_item_dialog(bufnr)
  local meta = vim.b[bufnr].taskmeister_edit_meta
  if not meta or not meta.id then
    vim.notify("No edit metadata found for this buffer", vim.log.levels.ERROR)
    return
  end

  local values = extract_editor_values(bufnr)
  local fields = meta.original.fields or {}
  local old_assigned = ""
  local current_assigned = fields["System.AssignedTo"]
  if type(current_assigned) == "table" then
    old_assigned = current_assigned.uniqueName or current_assigned.displayName or ""
  elseif type(current_assigned) == "string" then
    old_assigned = current_assigned
  end

  local patches = {}
  if values.title ~= (fields["System.Title"] or "") then
    table.insert(patches, { op = "replace", path = "/fields/System.Title", value = values.title })
  end
  if values.state ~= (fields["System.State"] or "New") then
    table.insert(patches, { op = "replace", path = "/fields/System.State", value = values.state })
  end
  if values.assigned_to ~= old_assigned then
    table.insert(patches, { op = "replace", path = "/fields/System.AssignedTo", value = values.assigned_to })
  end
  if values.description ~= (fields["System.Description"] or "") then
    table.insert(patches, { op = "replace", path = "/fields/System.Description", value = values.description })
  end

  if vim.tbl_isempty(patches) then
    vim.api.nvim_buf_set_option(bufnr, "modified", false)
    vim.notify("No changes to save for work item #" .. meta.id, vim.log.levels.INFO)
    return
  end

  local updated, err = api.update_work_item_checked(meta.id, patches, meta.rev)
  if not updated then
    if err and err.is_conflict then
      vim.notify(
        "Work item #" .. meta.id .. " was updated remotely since revision " .. tostring(meta.rev) .. ". Reload and retry.",
        vim.log.levels.WARN
      )
      return
    end
    vim.notify("Failed to save work item #" .. meta.id .. ": " .. (err and err.message or "unknown error"), vim.log.levels.ERROR)
    return
  end

  vim.b[bufnr].taskmeister_edit_meta = {
    id = updated.id,
    rev = updated.rev,
    original = updated,
  }
  local comments = get_comments_with_reactions(meta.id)
  render_edit_dialog(bufnr, updated, comments)
  vim.notify("Saved work item #" .. meta.id .. " at revision " .. tostring(updated.rev), vim.log.levels.INFO)
end

function M.add_comment_to_dialog(bufnr)
  if vim.bo[bufnr].modified then
    M.save_work_item_dialog(bufnr)
    if vim.bo[bufnr].modified then
      vim.notify("Could not save pending edits, comment not added", vim.log.levels.WARN)
      return
    end
  end
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
      end)
    end)
  end)
end

function M.react_to_comment_in_dialog(bufnr)
  if vim.bo[bufnr].modified then
    M.save_work_item_dialog(bufnr)
    if vim.bo[bufnr].modified then
      vim.notify("Could not save pending edits, reaction not added", vim.log.levels.WARN)
      return
    end
  end
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
            return string.format("%s %s", icons[reaction] or REACTION_ICONS[reaction] or "", reaction)
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
              end)
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

  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = bufnr, silent = true, desc = "Close edit dialog" })
  vim.keymap.set("n", "<Esc>", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = bufnr, silent = true, desc = "Close edit dialog" })
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
      M.save_work_item_dialog(bufnr)
    end,
    desc = "Save Taskmeister work item edit dialog",
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
  end)

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
  if config.ui and config.ui.use_signcolumn then
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
