local curl = require('plenary.curl')
local config = require('taskmeister.config')
local Job = require('plenary.job')

local M = {}

local DEFAULT_WORK_ITEM_FIELDS = {
  "System.Id",
  "System.Title",
  "System.WorkItemType",
  "System.State",
  "System.Description",
  "System.AssignedTo",
  "System.Tags",
}

-- Helper to construct API headers
local function get_headers(content_type)
  local opts = config.options

  return {
    ["Authorization"] = "Basic " .. vim.base64.encode(":" .. opts.personal_access_token),
    ["Content-Type"] = content_type or "application/json",
    ["Accept"] = "application/json;api-version=7.0",
  }
end

local function parse_error(response, fallback)
  if not response then
    return fallback
  end
  if type(response.body) == "string" and response.body ~= "" then
    local ok, decoded = pcall(vim.fn.json_decode, response.body)
    if ok and decoded then
      if decoded.message then
        return decoded.message
      end
      if decoded.error and decoded.error.message then
        return decoded.error.message
      end
    end
    return response.body
  end
  return fallback
end

local function normalize_reaction_type(reaction_type)
  if type(reaction_type) ~= "string" then
    return reaction_type
  end
  reaction_type = reaction_type:lower()
  local map = {
    thumbs_up = "like",
    thumbs_down = "dislike",
    rocket = "hooray",
    eyes = "confused",
  }
  return map[reaction_type] or reaction_type
end

local function aggregate_reactions(input)
  local reactions = {}
  if type(input) ~= "table" then
    return reactions
  end

  local function is_list(tbl)
    if type(tbl) ~= "table" then
      return false
    end
    local n = 0
    for k, _ in pairs(tbl) do
      if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
        return false
      end
      if k > n then
        n = k
      end
    end
    for i = 1, n do
      if rawget(tbl, i) == nil then
        return false
      end
    end
    return true
  end

  local function add(reaction_type, count)
    reaction_type = normalize_reaction_type(reaction_type)
    if not reaction_type or reaction_type == "" then
      return
    end
    local n = tonumber(count) or 1
    reactions[reaction_type] = (reactions[reaction_type] or 0) + n
  end

  if input.reactionType then
    add(input.reactionType, input.count)
    return reactions
  end

  if is_list(input) then
    for _, r in ipairs(input) do
      if type(r) == "table" then
        local reaction_type = r.reactionType
          or r.type
          or (type(r.reaction) == "table" and r.reaction.reactionType)
          or (type(r.value) == "table" and r.value.reactionType)
        local count = r.count
          or (type(r.value) == "table" and r.value.count)
        add(reaction_type, count)
      end
    end
    return reactions
  end

  for k, v in pairs(input) do
    if type(v) == "number" then
      add(k, v)
    elseif type(v) == "table" then
      local reaction_type = v.reactionType or v.type or k
      local count = v.count or v.value
      add(reaction_type, count)
    end
  end
  return reactions
end

local function reactions_is_empty(reactions)
  if type(reactions) ~= "table" then
    return true
  end
  return next(reactions) == nil
end

local function decode_json(body)
  local ok, decoded = pcall(function()
    if vim.json and vim.json.decode then
      return vim.json.decode(body or "")
    end
    return vim.fn.json_decode(body or "")
  end)
  if not ok then
    return nil
  end
  return decoded
end

local function run_on_main(callback, ...)
  local args = { ... }
  vim.schedule(function()
    callback(unpack(args))
  end)
end

-- Query work item IDs using WIQL
function M.query_work_item_ids(wiql)
  local opts = config.options

  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/wiql?api-version=7.0"
  local success, response = pcall(curl.post, url, {
    headers = get_headers(),
    body = vim.fn.json_encode({ query = wiql }),
    timeout = 5000,
  })
  if not success or response.status ~= 200 then
    local err = success and ("HTTP " .. response.status .. " - " .. response.body) or tostring(response)
    vim.notify("WIQL query failed: " .. err, vim.log.levels.ERROR)
    return {}
  end
  local result = vim.fn.json_decode(response.body)
  return vim.tbl_map(function(item) return item.id end, result.workItems or {})
end

function M.query_work_item_ids_async(wiql, callback)
  local opts = config.options
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/wiql?api-version=7.0"

  curl.post(url, {
    headers = get_headers(),
    body = vim.fn.json_encode({ query = wiql }),
    timeout = 5000,
    callback = function(response)
      if response.status ~= 200 then
        run_on_main(callback, nil, "HTTP " .. tostring(response.status) .. " - " .. tostring(response.body))
        return
      end
      local result = decode_json(response.body) or {}
      local ids = vim.tbl_map(function(item) return item.id end, result.workItems or {})
      run_on_main(callback, ids, nil)
    end,
    on_error = function(err)
      run_on_main(callback, nil, err and err.message or "request failed")
    end,
  })
end

-- Get work items in batch
function M.get_work_items_batch(ids, fields)
  local opts = config.options
  if vim.tbl_isempty(ids) then
    return {}
  end
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/workitemsbatch?api-version=7.0"
  local success, response = pcall(curl.post, url, {
    headers = get_headers(),
    body = vim.fn.json_encode({
      ids = ids,
      fields = fields or DEFAULT_WORK_ITEM_FIELDS,
    }),
    timeout = 5000,
  })
  if not success or response.status ~= 200 then
    local err = success and ("HTTP " .. response.status .. " - " .. response.body) or tostring(response)
    vim.notify("Batch fetch failed: " .. err, vim.log.levels.ERROR)
    return {}
  end
  local result = vim.fn.json_decode(response.body)
  if not result.value then
    vim.notify("No work items returned: " .. vim.inspect(result), vim.log.levels.ERROR)
    return {}
  end
  return result.value
end

function M.get_work_items_batch_async(ids, callback, fields)
  local opts = config.options
  if vim.tbl_isempty(ids) then
    run_on_main(callback, {}, nil)
    return
  end
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/workitemsbatch?api-version=7.0"
  curl.post(url, {
    headers = get_headers(),
    body = vim.fn.json_encode({
      ids = ids,
      fields = fields or DEFAULT_WORK_ITEM_FIELDS,
    }),
    timeout = 5000,
    callback = function(response)
      if response.status ~= 200 then
        run_on_main(callback, nil, "HTTP " .. tostring(response.status) .. " - " .. tostring(response.body))
        return
      end
      local result = decode_json(response.body)
      run_on_main(callback, (result and result.value) or {}, nil)
    end,
    on_error = function(err)
      run_on_main(callback, nil, err and err.message or "request failed")
    end,
  })
end

-- Create a work item
function M.create_work_item(type, patches)
  local opts = config.options
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/workitems/$" .. type .. "?api-version=7.0"
  local success, response = pcall(curl.post, url, {
    headers = get_headers("application/json-patch+json"),
    body = vim.fn.json_encode(patches),
    timeout = 5000,
  })
  if not success or response.status ~= 200 then
    local err = success and ("HTTP " .. response.status .. " - " .. response.body) or tostring(response)
    vim.notify("Create work item failed: " .. err, vim.log.levels.ERROR)
    error("Create work item failed")
  end
  return vim.fn.json_decode(response.body)
end

local function update_conflict_error(response, expected_rev)
  local message = parse_error(response, "HTTP " .. tostring(response.status))
  local body = (response.body or ""):lower()
  local is_conflict = expected_rev ~= nil and (
    response.status == 409 or response.status == 412
    or body:find("revision", 1, true) ~= nil
    or body:find("conflict", 1, true) ~= nil
    or body:find("does not match", 1, true) ~= nil
  )
  return { status = response.status, message = message, is_conflict = is_conflict }
end

function M.update_work_item_checked(id, patches, expected_rev)
  local opts = config.options
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/workitems/" .. id .. "?api-version=7.0"
  local payload = patches
  if expected_rev ~= nil then
    payload = vim.deepcopy(patches)
    table.insert(payload, 1, { op = "test", path = "/rev", value = expected_rev })
  end

  local success, response = pcall(curl.patch, url, {
    headers = get_headers("application/json-patch+json"),
    body = vim.fn.json_encode(payload),
    timeout = 5000,
  })

  if not success then
    return nil, { status = nil, message = tostring(response), is_conflict = false }
  end

  if response.status ~= 200 then
    return nil, update_conflict_error(response, expected_rev)
  end

  return vim.fn.json_decode(response.body), nil
end

function M.update_work_item_checked_async(id, patches, expected_rev, callback)
  local opts = config.options
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/workitems/" .. id .. "?api-version=7.0"
  local payload = patches
  if expected_rev ~= nil then
    payload = vim.deepcopy(patches)
    table.insert(payload, 1, { op = "test", path = "/rev", value = expected_rev })
  end

  curl.patch(url, {
    headers = get_headers("application/json-patch+json"),
    body = vim.fn.json_encode(payload),
    timeout = 5000,
    callback = function(response)
      if response.status ~= 200 then
        run_on_main(callback, nil, update_conflict_error(response, expected_rev))
        return
      end
      run_on_main(callback, decode_json(response.body) or {}, nil)
    end,
    on_error = function(err)
      run_on_main(callback, nil, { status = nil, message = err and err.message or "request failed", is_conflict = false })
    end,
  })
end

-- Update a work item
function M.update_work_item(id, patches)
  local opts = config.options
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/workitems/" .. id .. "?api-version=7.0"
  local success, response = pcall(curl.patch, url, {
    headers = get_headers("application/json-patch+json"),
    body = vim.fn.json_encode(patches),
    timeout = 5000,
  })

  if not success or response.status ~= 200 then
    local message = success and parse_error(response, "HTTP " .. tostring(response.status)) or tostring(response)
    vim.notify("Update work item failed: " .. (message or "Unknown error"), vim.log.levels.ERROR)
    error("Update work item failed")
  end

  return vim.fn.json_decode(response.body)
end

-- Get work item history
function M.get_work_item_history(id)
  local opts = config.options
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/workitems/" .. id .. "/updates?api-version=7.0"
  local success, response = pcall(curl.get, url, {
    headers = get_headers(),
    timeout = 5000,
  })
  if not success or response.status ~= 200 then
    local err = success and ("HTTP " .. response.status .. " - " .. response.body) or tostring(response)
    vim.notify("Fetch history failed: " .. err, vim.log.levels.ERROR)
    return {}
  end
  local result = vim.fn.json_decode(response.body)
  local function field_value(field)
    if type(field) ~= "table" then
      return ""
    end
    return field.value or field.newValue or field.oldValue or ""
  end

  local function parse_changed_date(changed_date)
    if not changed_date or changed_date == "" then
      return os.date("%Y-%m-%d %H:%M")
    end
    local date = tostring(changed_date):gsub("T", " "):gsub("Z", ""):gsub("%.%d+", "")
    if #date >= 16 then
      return date:sub(1, 16)
    end
    return date
  end

  return vim.tbl_map(function(update)
    local timestamp = parse_changed_date(update.changedDate)
    local user = update.changedBy and update.changedBy.displayName or "System"
    local history_field = update.fields and update.fields["System.History"] or nil
    local state_field = update.fields and update.fields["System.State"] or nil
    local history_value = field_value(history_field)
    local state_value = field_value(state_field)
    return {
      type = (history_value ~= "" and "comment") or "state_change",
      user = user,
      timestamp = timestamp,
      value = (history_value ~= "" and history_value) or state_value,
      rev = update.rev or 0,
    }
  end, result.value or {})
end

function M.get_work_item_comments(id)
  local opts = config.options
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project
    .. "/_apis/wit/workItems/" .. id .. "/comments?api-version=7.1-preview.4"
  local success, response = pcall(curl.get, url, {
    headers = get_headers(),
    timeout = 5000,
  })
  if not success or response.status ~= 200 then
    local err = success and ("HTTP " .. response.status .. " - " .. response.body) or tostring(response)
    vim.notify("Fetch comments failed: " .. err, vim.log.levels.ERROR)
    return {}
  end

  local result = vim.fn.json_decode(response.body)
  local comments = {}
  for _, comment in ipairs(result.comments or result.value or {}) do
    local reactions = aggregate_reactions(
      comment.reactions
        or comment.reactionCounts
        or comment.reactionsSummary
        or comment.reactionSummary
    )
    if comment.id and reactions_is_empty(reactions) then
      reactions = M.get_comment_reactions(id, comment.id)
    end
    table.insert(comments, {
      id = comment.id,
      text = comment.text or "",
      created_by = comment.createdBy and comment.createdBy.displayName or "System",
      created_date = comment.createdDate or "",
      reactions = reactions,
    })
  end
  return comments
end

function M.get_work_item_comments_async(id, callback)
  local opts = config.options
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project
    .. "/_apis/wit/workItems/" .. id .. "/comments?api-version=7.1-preview.4"
  curl.get(url, {
    headers = get_headers(),
    timeout = 5000,
    callback = function(response)
      if response.status ~= 200 then
        run_on_main(callback, nil, "HTTP " .. tostring(response.status) .. " - " .. tostring(response.body))
        return
      end
      local result = decode_json(response.body) or {}
      local comments = {}
      for _, comment in ipairs(result.comments or result.value or {}) do
        local reactions = aggregate_reactions(
          comment.reactions
            or comment.reactionCounts
            or comment.reactionsSummary
            or comment.reactionSummary
        )
        table.insert(comments, {
          id = comment.id,
          text = comment.text or "",
          created_by = comment.createdBy and comment.createdBy.displayName or "System",
          created_date = comment.createdDate or "",
          reactions = reactions,
        })
      end
      local pending = 0
      local finalized = false

      local function finish()
        if finalized then
          return
        end
        if pending == 0 then
          finalized = true
          run_on_main(callback, comments, nil)
        end
      end

      for idx, comment in ipairs(comments) do
        if comment.id and reactions_is_empty(comment.reactions) then
          pending = pending + 1
          M.get_comment_reactions_async(id, comment.id, function(reactions)
            comments[idx].reactions = reactions or {}
            pending = pending - 1
            finish()
          end)
        end
      end

      finish()
    end,
    on_error = function(err)
      run_on_main(callback, nil, err and err.message or "request failed")
    end,
  })
end

function M.add_work_item_comment(id, text)
  local opts = config.options
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project
    .. "/_apis/wit/workItems/" .. id .. "/comments?api-version=7.1-preview.4"
  local success, response = pcall(curl.post, url, {
    headers = get_headers("application/json"),
    body = vim.fn.json_encode({ text = text }),
    timeout = 5000,
  })
  if not success or (response.status ~= 200 and response.status ~= 201) then
    local err = success and ("HTTP " .. response.status .. " - " .. response.body) or tostring(response)
    return nil, err
  end
  return vim.fn.json_decode(response.body), nil
end

function M.add_work_item_comment_async(id, text, callback)
  local opts = config.options
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project
    .. "/_apis/wit/workItems/" .. id .. "/comments?api-version=7.1-preview.4"
  curl.post(url, {
    headers = get_headers("application/json"),
    body = vim.fn.json_encode({ text = text }),
    timeout = 5000,
    callback = function(response)
      if response.status ~= 200 and response.status ~= 201 then
        run_on_main(callback, nil, "HTTP " .. tostring(response.status) .. " - " .. tostring(response.body))
        return
      end
      run_on_main(callback, decode_json(response.body) or {}, nil)
    end,
    on_error = function(err)
      run_on_main(callback, nil, err and err.message or "request failed")
    end,
  })
end

-- Get reactions for a comment (comment_id is a comment id from comments endpoint)
function M.get_comment_reactions(work_item_id, comment_id)
  local opts = config.options
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/workItems/" .. work_item_id .. "/comments/" .. comment_id .. "/reactions?api-version=7.1-preview.1"
  local success, response = pcall(curl.get, url, {
    headers = get_headers(),
    timeout = 5000,
  })
  if not success or response.status ~= 200 then
    local body = (success and response and response.body) and tostring(response.body):lower() or ""
    if body:find("does not exist", 1, true) or body:find("not found", 1, true) then
      return {}
    end
    local err = success and ("HTTP " .. response.status .. " - " .. response.body) or tostring(response)
    vim.notify("Fetch reactions failed: " .. err, vim.log.levels.WARN)
    return {}
  end
  local result = vim.fn.json_decode(response.body)
  return aggregate_reactions(result.value or result.reactions or result)
end

function M.get_comment_reactions_async(work_item_id, comment_id, callback)
  local opts = config.options
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project
    .. "/_apis/wit/workItems/" .. work_item_id .. "/comments/" .. comment_id .. "/reactions?api-version=7.1-preview.1"
  curl.get(url, {
    headers = get_headers(),
    timeout = 5000,
    callback = function(response)
      if response.status ~= 200 then
        local body = response.body and tostring(response.body):lower() or ""
        if body:find("does not exist", 1, true) or body:find("not found", 1, true) then
          run_on_main(callback, {})
          return
        end
        vim.notify(
          "Fetch reactions failed: HTTP " .. tostring(response.status) .. " - " .. tostring(response.body),
          vim.log.levels.WARN
        )
        run_on_main(callback, {})
        return
      end
      local result = decode_json(response.body) or {}
      run_on_main(callback, aggregate_reactions(result.value or result.reactions or result))
    end,
    on_error = function(err)
      vim.notify("Fetch reactions failed: " .. (err and err.message or "request failed"), vim.log.levels.WARN)
      run_on_main(callback, {})
    end,
  })
end

-- Add a reaction to a comment
function M.add_comment_reaction(work_item_id, comment_id, reaction_type)
  local opts = config.options
  local normalized = normalize_reaction_type(reaction_type)
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/workItems/" .. work_item_id .. "/comments/" .. comment_id .. "/reactions/" .. normalized .. "?api-version=7.1-preview.1"
  local headers = get_headers("application/json")
  headers["Content-Length"] = "0"
  local success, response = pcall(curl.put, url, {
    headers = headers,
    body = "",
    timeout = 5000,
  })
  if not success or response.status ~= 200 then
    local err = success and ("HTTP " .. response.status .. " - " .. response.body) or tostring(response)
    err = err .. " (reactionType=" .. tostring(normalized) .. ")"
    vim.notify("Add reaction failed: " .. err, vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.add_comment_reaction_async(work_item_id, comment_id, reaction_type, callback)
  local opts = config.options
  local normalized = normalize_reaction_type(reaction_type)
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/workItems/" .. work_item_id .. "/comments/" .. comment_id .. "/reactions/" .. normalized .. "?api-version=7.1-preview.1"
  local headers = get_headers("application/json")
  headers["Content-Length"] = "0"
  curl.put(url, {
    headers = headers,
    body = "",
    timeout = 5000,
    callback = function(response)
      if response.status ~= 200 then
        run_on_main(callback, false, "HTTP " .. tostring(response.status) .. " - " .. tostring(response.body) .. " (reactionType=" .. tostring(normalized) .. ")")
        return
      end
      run_on_main(callback, true, nil)
    end,
    on_error = function(err)
      run_on_main(callback, false, err and err.message or "request failed")
    end,
  })
end

-- Remove a reaction from a comment
function M.remove_comment_reaction(work_item_id, comment_id, reaction_type)
  local opts = config.options
  local normalized = normalize_reaction_type(reaction_type)
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/workItems/" .. work_item_id .. "/comments/" .. comment_id .. "/reactions/" .. normalized .. "?api-version=7.1-preview.1"
  local headers = get_headers("application/json")
  headers["Content-Length"] = "0"
  local success, response = pcall(curl.delete, url, {
    headers = headers,
    body = "",
    timeout = 5000,
  })
  if not success or response.status ~= 200 then
    local err = success and ("HTTP " .. response.status .. " - " .. response.body) or tostring(response)
    err = err .. " (reactionType=" .. tostring(normalized) .. ")"
    vim.notify("Remove reaction failed: " .. err, vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.remove_comment_reaction_async(work_item_id, comment_id, reaction_type, callback)
  local opts = config.options
  local normalized = normalize_reaction_type(reaction_type)
  local url = opts.base_url .. "/" .. opts.organization .. "/" .. opts.project .. "/_apis/wit/workItems/" .. work_item_id .. "/comments/" .. comment_id .. "/reactions/" .. normalized .. "?api-version=7.1-preview.1"
  local headers = get_headers("application/json")
  headers["Content-Length"] = "0"
  curl.delete(url, {
    headers = headers,
    body = "",
    timeout = 5000,
    callback = function(response)
      if response.status ~= 200 then
        run_on_main(callback, false, "HTTP " .. tostring(response.status) .. " - " .. tostring(response.body) .. " (reactionType=" .. tostring(normalized) .. ")")
        return
      end
      run_on_main(callback, true, nil)
    end,
    on_error = function(err)
      run_on_main(callback, false, err and err.message or "request failed")
    end,
  })
end

-- Old functions start

function M.get_workitem_type_and_title(wi_ids, callback)
  local opts = config.options

  if not opts.personal_access_token or not opts.organization or not opts.project then
    print("Please configure the plugin with PAT, organization, and project")
    print(opts.project)
    return
  end

  local api_version = "7.0"
  local ids_str = table.concat(wi_ids, ',')
  local url = string.format("%s/%s/%s/_apis/wit/workitems?ids=%s&fields=System.Id,System.WorkItemType,System.Title&?api-version=%s",
                            opts.base_url, opts.organization, opts.project, ids_str, api_version)
  Job:new({
    command = 'curl',
    args = {
      '-X', 'GET',
      '-u', string.format(':%s', opts.personal_access_token),
      '-H', 'Content-Type: application/json',
      url
    },
    on_exit = function(job, exit_code)
      if exit_code == 0 then
        callback(job:result())
      else
        callback(nil)
      end
    end
  }):start()
end

function M.get_workitem_type_and_title2(wi_ids, fields_to_fetch, callback)
  local opts = config.options

  if not opts.personal_access_token or not opts.organization or not opts.project then
    print("Please configure the plugin with PAT, organization, and project")
    print(opts.project)
    return
  end

  local api_version = "7.0"
  local ids_str = table.concat(wi_ids, ',')
  local fields_str = table.concat(fields_to_fetch, ',')
  local url = string.format("%s/%s/%s/_apis/wit/workitems?ids=%s&fields=%s&?api-version=%s",
                            opts.base_url, opts.organization, opts.project, ids_str, fields_str, api_version)
  Job:new({
    command = 'curl',
    args = {
      '-X', 'GET',
      '-u', string.format(':%s', opts.personal_access_token),
      '-H', 'Content-Type: application/json',
      url
    },
    on_exit = function(job, exit_code)
      if exit_code == 0 then
        callback(job:result())
      else
        callback(nil)
      end
    end
  }):start()
end

function M.update_workitem(work_item, callback)
  local opts = config.options
  if not opts.personal_access_token or not opts.organization or not opts.project then
    print("Please configure the plugin with PAT, organization, and project")
    return
  end

  local api_version = "7.0"
  local url = string.format("%s/%s/%s/_apis/wit/workitems?ids=%s&fields=%s&?api-version=%s",
                            opts.base_url, opts.organization, opts.project, work_item.id, api_version)
  Job:new({
    command = 'curl',
    args = {
      '-X', 'PATCH',
      '-u', string.format(':%s', opts.personal_access_token),
      --'-H', 'Authorization: Basic ' .. vim.fn.base64_encode(":" .. opts.personal_access_token),
      '-H', 'Content-Type: application/json-patch+json',
      '-H', 'If-Match: ' .. work_item.rev,
      '-d', work_item.getJsonDiff(),
      '-d', string.format('[{"op": "add", "path": "/fields/System.Title", "value": "%s"}]', 'Test title'),
      url
    },
    on_exit = function(job, exit_code)
      if exit_code == 0 then
        callback(job:result())
      else
        callback(nil)
      end
    end
  }):start()

end

-- Old functions end

return M
