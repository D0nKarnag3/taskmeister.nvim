local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")
local api = require("taskmeister.api")
local config = require("taskmeister.config")

local M = {}

local DASHBOARD_FIELDS = {
  "System.Id",
  "System.Title",
  "System.WorkItemType",
  "System.State",
  "System.AssignedTo",
  "System.ChangedDate",
  "System.Tags",
  "System.Description",
}

local SECTION_PRIORITY = {
  Blocked = 1,
  Stale = 2,
  Active = 3,
  New = 4,
  ["Recently changed"] = 5,
  Other = 6,
}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function field(item, name)
  return ((item or {}).fields or {})[name]
end

local function item_id(item)
  return item and (item.id or field(item, "System.Id")) or nil
end

local function as_list(value)
  if type(value) == "table" then
    return value
  end
  if value == nil then
    return {}
  end
  return { value }
end

local function escape_wiql(value)
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function wiql_list(values)
  local escaped = {}
  for _, value in ipairs(as_list(values)) do
    if value ~= nil and value ~= "" then
      table.insert(escaped, escape_wiql(value))
    end
  end
  return table.concat(escaped, ", ")
end

local function build_wiql(opts)
  local clauses = {
    "[System.TeamProject] = @project",
    "[System.AssignedTo] = @Me",
  }
  local closed_states = wiql_list(opts.closed_states)
  if closed_states ~= "" then
    table.insert(clauses, "[System.State] NOT IN (" .. closed_states .. ")")
  end
  return "SELECT [System.Id] FROM workitems WHERE "
    .. table.concat(clauses, " AND ")
    .. " ORDER BY [System.ChangedDate] DESC"
end

local function contains_case_insensitive(values, value)
  if value == nil then
    return false
  end
  local needle = tostring(value):lower()
  for _, candidate in ipairs(as_list(values)) do
    if tostring(candidate):lower() == needle then
      return true
    end
  end
  return false
end

local function has_blocked_tag(item, opts)
  local tags = field(item, "System.Tags")
  if type(tags) ~= "string" or tags == "" then
    return false
  end
  local wanted = {}
  for _, tag in ipairs(as_list(opts.blocked_tags)) do
    wanted[tostring(tag):lower()] = true
  end
  for tag in tags:gmatch("[^;]+") do
    if wanted[trim(tag):lower()] then
      return true
    end
  end
  return false
end

local function parse_changed_timestamp(changed_date)
  if type(changed_date) ~= "string" then
    return nil
  end
  local year, month, day, hour, min, sec = changed_date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T%s](%d%d):(%d%d):(%d%d)")
  if not year then
    year, month, day = changed_date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    hour, min, sec = "0", "0", "0"
  end
  if not year then
    return nil
  end
  return os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  })
end

local function days_since(changed_date)
  local timestamp = parse_changed_timestamp(changed_date)
  if not timestamp then
    return nil
  end
  local seconds = os.difftime(os.time(), timestamp)
  if seconds < 0 then
    return 0
  end
  return math.floor(seconds / 86400)
end

local function short_date(changed_date)
  if type(changed_date) == "string" and #changed_date >= 10 then
    return changed_date:sub(1, 10)
  end
  return "unknown"
end

local function assigned_to_display(item)
  local assigned = field(item, "System.AssignedTo")
  if type(assigned) == "table" then
    return assigned.displayName or assigned.uniqueName or "Unassigned"
  end
  if type(assigned) == "string" and assigned ~= "" then
    return assigned
  end
  return "Unassigned"
end

local function classify_item(item, opts)
  if has_blocked_tag(item, opts) then
    return "Blocked"
  end

  local age = days_since(field(item, "System.ChangedDate"))
  if age and age >= (tonumber(opts.stale_after_days) or 14) then
    return "Stale"
  end

  local state = field(item, "System.State")
  if contains_case_insensitive(opts.active_states, state) then
    return "Active"
  end
  if contains_case_insensitive(opts.new_states, state) then
    return "New"
  end
  if age and age <= (tonumber(opts.recent_days) or 7) then
    return "Recently changed"
  end
  return "Other"
end

local function compact_title(title)
  title = tostring(title or "Untitled"):gsub("%s+", " ")
  if #title > 90 then
    return title:sub(1, 87) .. "..."
  end
  return title
end

local function decorate_items(items, opts)
  local entries = {}
  for _, item in ipairs(items or {}) do
    local id = item_id(item)
    if id then
      local section = classify_item(item, opts)
      local work_type = field(item, "System.WorkItemType") or "Work Item"
      local state = field(item, "System.State") or "Unknown"
      local title = compact_title(field(item, "System.Title"))
      local changed_date = field(item, "System.ChangedDate")
      table.insert(entries, {
        item = item,
        id = id,
        section = section,
        priority = SECTION_PRIORITY[section] or SECTION_PRIORITY.Other,
        changed_at = parse_changed_timestamp(changed_date) or 0,
        display = string.format(
          "[%s] WI%s %s %s %s  Changed: %s",
          section,
          tostring(id),
          work_type,
          state,
          title,
          short_date(changed_date)
        ),
        ordinal = table.concat({
          section,
          "WI" .. tostring(id),
          work_type,
          state,
          title,
          assigned_to_display(item),
          field(item, "System.Tags") or "",
        }, " "),
      })
    end
  end

  table.sort(entries, function(left, right)
    if left.priority ~= right.priority then
      return left.priority < right.priority
    end
    if left.changed_at ~= right.changed_at then
      return left.changed_at > right.changed_at
    end
    return tostring(left.id) < tostring(right.id)
  end)

  return entries
end

local function split_text(value)
  if not value or value == "" then
    return { "" }
  end
  return vim.split(value, "\n", { plain = true })
end

local function preview_lines(entry)
  local item = entry.item
  local lines = {
    "WI" .. tostring(entry.id) .. " " .. tostring(field(item, "System.Title") or "Untitled"),
    "",
    "Section: " .. entry.section,
    "Type: " .. tostring(field(item, "System.WorkItemType") or "Work Item"),
    "State: " .. tostring(field(item, "System.State") or "Unknown"),
    "Assigned: " .. assigned_to_display(item),
    "Changed: " .. tostring(field(item, "System.ChangedDate") or "unknown"),
    "Tags: " .. tostring(field(item, "System.Tags") or ""),
    "",
    "Description:",
  }
  local description = field(item, "System.Description") or ""
  if description == "" then
    table.insert(lines, "  (no description)")
  else
    for _, line in ipairs(split_text(description)) do
      table.insert(lines, line)
    end
  end
  return lines
end

local function selected_dashboard_entry(prompt_bufnr)
  local selected = action_state.get_selected_entry()
  if not selected or not selected.value then
    vim.notify("No work item selected", vim.log.levels.INFO)
    return nil
  end
  return selected.value
end

local function reopen(opts)
  vim.schedule(function()
    M.open(opts)
  end)
end

local function map_action(map, lhs, callback, desc)
  map("i", lhs, callback, { desc = desc })
  map("n", lhs, callback, { desc = desc })
end

local function open_picker(entries, opts)
  pickers.new(opts.telescope or {}, {
    prompt_title = "Taskmeister Dashboard (" .. tostring(#entries) .. " items)",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.display,
          ordinal = entry.ordinal,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts.telescope or {}),
    previewer = previewers.new_buffer_previewer({
      define_preview = function(self, entry)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_lines(entry.value))
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      local function open_selected()
        local entry = selected_dashboard_entry(prompt_bufnr)
        if not entry then
          return
        end
        actions.close(prompt_bufnr)
        require("taskmeister.ui").open_work_item(tostring(entry.id))
      end

      local function edit_selected()
        local entry = selected_dashboard_entry(prompt_bufnr)
        if not entry then
          return
        end
        actions.close(prompt_bufnr)
        require("taskmeister.ui").open_work_item_edit_dialog(tostring(entry.id))
      end

      local function browser_selected()
        local entry = selected_dashboard_entry(prompt_bufnr)
        if not entry then
          return
        end
        actions.close(prompt_bufnr)
        require("taskmeister").open_work_item_in_browser_by_id(tostring(entry.id))
      end

      local function comment_selected()
        local entry = selected_dashboard_entry(prompt_bufnr)
        if not entry then
          return
        end
        actions.close(prompt_bufnr)
        vim.ui.input({ prompt = "Comment: " }, function(comment)
          if not comment or comment == "" then
            return
          end
          api.add_work_item_comment_async(entry.id, comment, function(_, err)
            if err then
              vim.notify("Failed to add comment to WI" .. tostring(entry.id) .. ": " .. err, vim.log.levels.ERROR)
              return
            end
            vim.notify("Added comment to WI" .. tostring(entry.id), vim.log.levels.INFO)
            reopen(opts)
          end)
        end)
      end

      local function change_state_selected()
        local entry = selected_dashboard_entry(prompt_bufnr)
        if not entry then
          return
        end
        actions.close(prompt_bufnr)
        vim.ui.input({ prompt = "New State: " }, function(state)
          if not state or state == "" then
            return
          end
          local patches = {
            { op = "replace", path = "/fields/System.State", value = state },
          }
          api.update_work_item_checked_async(entry.id, patches, entry.item.rev, function(_, err)
            if err then
              vim.notify(
                "Failed to update WI" .. tostring(entry.id) .. ": " .. (err.message or "unknown error"),
                vim.log.levels.ERROR
              )
              return
            end
            vim.notify("Updated WI" .. tostring(entry.id) .. " state to " .. state, vim.log.levels.INFO)
            reopen(opts)
          end)
        end)
      end

      local function refresh_dashboard()
        actions.close(prompt_bufnr)
        reopen(opts)
      end

      actions.select_default:replace(open_selected)
      map_action(map, "<C-o>", open_selected, "Open work item")
      map_action(map, "<C-e>", edit_selected, "Edit work item")
      map_action(map, "<C-b>", browser_selected, "Open in browser")
      map_action(map, "<C-c>", comment_selected, "Add comment")
      map_action(map, "<C-s>", change_state_selected, "Change state")
      map_action(map, "<C-r>", refresh_dashboard, "Refresh dashboard")

      return true
    end,
  }):find()
end

local function cap_ids(ids, max_items)
  local limit = tonumber(max_items) or 100
  if limit < 1 then
    limit = 100
  end
  limit = math.min(limit, 200)
  if #ids <= limit then
    return ids
  end
  local capped = {}
  for i = 1, limit do
    capped[i] = ids[i]
  end
  return capped
end

function M.open(opts)
  opts = opts or {}
  local dashboard_opts = vim.tbl_deep_extend("force", {}, config.get().dashboard or {}, opts.dashboard or {})
  local wiql = opts.wiql or build_wiql(dashboard_opts)

  vim.notify("Loading Taskmeister dashboard...", vim.log.levels.INFO)
  api.query_work_item_ids_async(wiql, function(ids, query_err)
    if query_err then
      vim.notify("Taskmeister dashboard query failed: " .. query_err, vim.log.levels.ERROR)
      return
    end
    ids = cap_ids(ids or {}, dashboard_opts.max_items)
    if #ids == 0 then
      vim.notify("Taskmeister dashboard: no assigned open work items", vim.log.levels.INFO)
      return
    end

    api.get_work_items_batch_async(ids, function(items, fetch_err)
      if fetch_err then
        vim.notify("Taskmeister dashboard fetch failed: " .. fetch_err, vim.log.levels.ERROR)
        return
      end
      local entries = decorate_items(items or {}, dashboard_opts)
      if #entries == 0 then
        vim.notify("Taskmeister dashboard: no work items returned", vim.log.levels.INFO)
        return
      end
      open_picker(entries, opts)
    end, DASHBOARD_FIELDS)
  end)
end

M._build_wiql = build_wiql
M._classify_item = classify_item
M._decorate_items = decorate_items

return M
