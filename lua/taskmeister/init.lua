local config = require('taskmeister.config')
local virt = require('taskmeister.wi_virtual_text')
local Job = require('plenary.job')
local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local previewers = require('telescope.previewers')
local api = require('taskmeister.api')
local ui = require('taskmeister.ui')

local M = {}

function M.setup(opts)
  config.set(opts)
  M.register()

  --if config.options.enable_work_item_details_auto_command then
    --vim.cmd [[
      --augroup AzureDevOps
        --autocmd!
        --autocmd BufRead,TextChanged,TextChangedI * lua require('azure_devops').debounce_add_work_item_virtual_text()
      --augroup END
    --]]
  --end
end

function M.debounce_add_work_item_virtual_text()
  M._debounce(virt.show_work_item_virtual_text(), 3000)
end

function M._debounce2(fn, delay)
  local timer_id
  return function(...)
    if timer_id then
      vim.fn.timer_stop(timer_id)
    end
    local args = {...}
    timer_id = vim.fn.timer_start(delay, function()
      fn(unpack(args))
      timer_id = nil
    end)
  end
end

function M._debounce(fn, delay)
  local timer = nil
  return function(...)
    if timer then
      timer:stop()
      timer = nil
    end
    local args = {...}
    timer = vim.defer_fn(function()
      fn(unpack(args))
      timer = nil
    end, delay)
  end
end

function M.prompt_search_work_items()
  local opts = config.options

  if not opts.personal_access_token or not opts.organization or not opts.project then
    print("Please configure the plugin with PAT, organization, and project")
    return
  end

  local api_version = "7.0"
  local url = string.format("%s/%s/%s/_apis/wit/wiql?api-version=%s",
                            opts.base_url, opts.organization, opts.project, api_version)

  local query = {
    query = "SELECT [System.Id], [System.Title] FROM workitems"
  }

  Job:new({
    command = 'curl',
    args = {
      '-X', 'POST',
      '-u', string.format(':%s', opts.personal_access_token),
      '-H', 'Content-Type: application/json',
      '-d', vim.fn.json_encode(query),
      url
    },
    on_exit = function(job)
      vim.schedule(function()
        if job.code == 0 then
          local result_ids = vim.fn.json_decode(job:result())
          local work_item_ids = {}
          for _, item in ipairs(result_ids.workItems) do
            table.insert(work_item_ids, item.id)
          end

          if #work_item_ids > 0 then
            local ids_str = table.concat(work_item_ids, ',')
            local url = string.format("%s/%s/%s/_apis/wit/workitems?ids=%s&fields=System.Id,System.WorkItemType,System.Title&?api-version=%s",
                                      opts.base_url, opts.organization, opts.project, ids_str, api_version)
            Job:new({
              command = 'curl',
              args = {
                '-X', 'GET',
                '-u', string.format(':%s', opts.personal_access_token),
                '-H', 'Content-Type: application/json',
                '-d', vim.fn.json_encode(query),
                url
              },
              on_exit = function(job)
                vim.schedule(function()
                  local result = vim.fn.json_decode(table.concat(job:result(), '\n'))
                  if result and result.value then
                    local work_items = {}
                    for _, item in ipairs(result.value) do
                      table.insert(work_items, {
                        id = item.id,
                        type = item.fields['System.WorkItemType'],
                        title = item.fields['System.Title']
                      })
                    end

                    pickers.new({}, {
                      promp_title = 'Work items',
                      finder = finders.new_table {
                        results = work_items,
                        entry_maker = function(entry)
                          return {
                            value = entry,
                            display = string.format('[%s %d]: %s',entry.type, entry.id, entry.title),
                            ordinal = tostring(entry.id .. entry.type .. entry.title)
                          }
                        end
                      },
                      sorter = conf.generic_sorter({}),
                      previewer = previewers.new_buffer_previewer({
                        define_preview = function(self, entry, status)
                          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { entry.value.title })
                        end
                      }),
                      attach_mapping = function(prompt_bufnr, map)
                        actions.select_default:replace(function()
                          local selection = action_state.get_selected_entry()
                          actions.close(prompt_bufnr)
                          print('Selected Work item ID: ' .. selection.value.id)
                        end)
                        map('i', '<C-o>', function()
                          local selection = action_state.get_selected_entry()
                          print('Selected Work item ID: ' .. selection.value.id)
                        end)
                        return true
                      end
                    }):find()
                  end
                end)
              end
            }):start()
          end
        end
      end)
    end
  }):start()
end

local function is_wsl()
  local output = vim.fn.system('uname -r')
  return output:find('-microsoft', 1, true) ~= nil
end

function M.open_work_item_in_browser()
  local opts = config.options
  local current_word = vim.fn.expand('<cword>')
  local pattern = '^WI(%d+)$'
  local wid = string.match(current_word, pattern)

  if wid then
    local url = string.format("%s/%s/%s/_workitems/edit/%s", opts.base_url, opts.organization, opts.project, wid)

    if vim.fn.has('win32') == 1 or is_wsl() then
      vim.fn.jobstart({ 'cmd.exe', '/c', 'start', '', url })
    elseif vim.fn.has('unix') == 1 or vim.fn.has('mac') == 1 then
      vim.fn.jobstart({ 'xdg-open', url })
    end
  end
end

local function resolve_work_item_id(id_arg)
  local id = id_arg
  if not id or id == "" then
    local current_word = vim.fn.expand('<cword>')
    id = current_word:match('^WI(%d+)$')
  end
  if not id or id == "" then
    id = vim.fn.input("Work Item ID: ")
  end
  if not id or id == "" then
    return nil
  end
  local numeric_id = tonumber(id)
  if not numeric_id then
    vim.notify("Invalid work item ID: " .. tostring(id), vim.log.levels.ERROR)
    return nil
  end
  return tostring(numeric_id)
end

function M.open_work_item_in_browser_by_id(id_arg)
  local wid = resolve_work_item_id(id_arg)
  if not wid then
    vim.notify("Please provide a work item ID (e.g. :Taskmeister browser 123)", vim.log.levels.ERROR)
    return
  end
  local opts = config.options
  local url = string.format("%s/%s/%s/_workitems/edit/%s", opts.base_url, opts.organization, opts.project, wid)
  if vim.fn.has('win32') == 1 or is_wsl() then
    vim.fn.jobstart({ 'cmd.exe', '/c', 'start', '', url })
  elseif vim.fn.has('unix') == 1 or vim.fn.has('mac') == 1 then
    vim.fn.jobstart({ 'xdg-open', url })
  end
end

function M.fetch_and_show_work_item_details()
  local wid = resolve_work_item_id()
  local fields = {
    "System.Id",
    "System.WorkItemType",
    "System.Title",
    "System.State",
    "System.AssignedTo",
    "System.Description",
    "Microsoft.VSTS.Scheduling.OriginalEstimate",
    "Microsoft.VSTS.Scheduling.CompletedWork",
    "Microsoft.VSTS.Scheduling.RemainingWork"
  }

  if wid then
    api.get_workitem_type_and_title2({ wid }, fields, function(data)
      if data == nil then
        return
      end
      vim.schedule(function()
        local result = vim.fn.json_decode(table.concat(data, '\n'))
        if result and result.value then
          local formatted_content = format_work_item(result.value)
          create_floating_window2(formatted_content)
          --show_virtual_text_below_word(result.value)
        end
      end)
    end)
  else
    vim.notify("Please provide a work item ID (e.g. :Taskmeister details 123)", vim.log.levels.ERROR)
  end
end

function M.fetch_and_show_work_item_details_by_id(id_arg)
  local wid = resolve_work_item_id(id_arg)
  if not wid then
    vim.notify("Please provide a work item ID (e.g. :Taskmeister details 123)", vim.log.levels.ERROR)
    return
  end
  local fields = {
    "System.Id",
    "System.WorkItemType",
    "System.Title",
    "System.State",
    "System.AssignedTo",
    "System.Description",
    "Microsoft.VSTS.Scheduling.OriginalEstimate",
    "Microsoft.VSTS.Scheduling.CompletedWork",
    "Microsoft.VSTS.Scheduling.RemainingWork"
  }

  api.get_workitem_type_and_title2({ wid }, fields, function(data)
    if data == nil then
      return
    end
    vim.schedule(function()
      local result = vim.fn.json_decode(table.concat(data, '\n'))
      if result and result.value then
        local formatted_content = format_work_item(result.value)
        create_floating_window2(formatted_content)
      end
    end)
  end)
end

function M.edit_work_item(id_arg)
  local id = resolve_work_item_id(id_arg)
  if not id then
    vim.notify("Please provide a work item ID (e.g. :Taskmeister edit 123)", vim.log.levels.ERROR)
    return
  end
  ui.open_work_item_edit_dialog(id)
end

function create_floating_window(content)
  -- Define dimensions for the window
  local width = math.ceil(vim.o.columns * 0.6)   -- 60% of editor width
  local height = math.ceil(vim.o.lines * 0.5)    -- 50% of editor height

  -- Create a buffer
  local buf = vim.api.nvim_create_buf(false, true)   -- No file, not listed

  -- Set buffer content (content is a table of lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)

  -- Define window options (border, position, etc.)
  local opts = {
    style = "minimal",
    relative = "editor",
    width = width,
    height = height,
    row = math.ceil((vim.o.lines - height) / 2),
    col = math.ceil((vim.o.columns - width) / 2),
    border = "rounded"
  }

  -- Create the floating window
  vim.api.nvim_open_win(buf, true, opts)

  -- Optional: Close the window when pressing any key (you can customize this behavior)
  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '<cmd>close<CR>', { noremap = true, silent = true })
end

function create_floating_window2(content)
  -- Validate that content is a table of strings
  print(vim.inspect(content))
  assert(type(content) == "table", "Expected content to be a table of strings")

  -- Get the current buffer and window details
  local width = vim.api.nvim_get_option("columns")
  local height = vim.api.nvim_get_option("lines")

  -- Window dimensions
  local win_width = math.floor(width * 0.5)  -- 50% of the screen width
  local win_height = math.min(10, #content)  -- Set height based on content (max 10 lines)

  -- Window position: Set below the current line
  local row = vim.fn.line('.') -- Current line
  local col = vim.fn.col('.')  -- Current column

  -- Create a buffer for the floating window
  local buf = vim.api.nvim_create_buf(false, true) -- No file, ephemeral buffer

  -- Set the buffer content to the work item details
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)

  -- Create a floating window with the desired dimensions and position
  local win = vim.api.nvim_open_win(buf, false, {
    relative = 'cursor',  -- Relative to the current cursor position
    width = win_width,
    height = win_height,
    row = 1,  -- Position just below the cursor
    col = 0,  -- Align to the current cursor's column
    style = 'minimal',  -- No borders, minimal interface
    border = 'single'  -- Add a simple border
  })

  -- Optional: Set the window to close automatically when the cursor moves
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = 0,
    callback = function()
      vim.api.nvim_win_close(win, true)  -- Close the floating window
    end
  })
end

function M.register()
  local subcommands = {
    open = true,
    edit = true,
    create = true,
    list = true,
    comment = true,
    browser = true,
    details = true,
    ["vt-show"] = true,
    ["vt-clear"] = true,
  }

  vim.api.nvim_create_user_command("Taskmeister", function(args)
    local subcmd = args.fargs[1]
    if not subcmd or subcmd == "" then
      vim.notify("Usage: :Taskmeister <open|edit|create|list|comment|browser|details|vt-show|vt-clear>", vim.log.levels.ERROR)
      return
    end

    if subcmd == "open" then
      local id = resolve_work_item_id(args.fargs[2])
      if not id then
        vim.notify("Please provide a work item ID (e.g. :Taskmeister open 123)", vim.log.levels.ERROR)
        return
      end
      require("taskmeister.ui").open_work_item(id)
    elseif subcmd == "edit" then
      M.edit_work_item(args.fargs[2])
    elseif subcmd == "create" then
      local item_type = table.concat(args.fargs, " ", 2)
      if not item_type or item_type == "" then
        vim.notify("Please provide a work item type (e.g. :Taskmeister create Task)", vim.log.levels.ERROR)
        return
      end
      require("taskmeister.ui").create_work_item(item_type)
    elseif subcmd == "list" then
      local search = table.concat(args.fargs, " ", 2)
      if search == "" then
        require("taskmeister.telescope").work_items({})
      else
        require("taskmeister.telescope").work_items({ search = search })
      end
    elseif subcmd == "comment" then
      local id = resolve_work_item_id(args.fargs[2])
      if not id then
        vim.notify("Please provide a work item ID (e.g. :Taskmeister comment 123)", vim.log.levels.ERROR)
        return
      end
      local comment = vim.fn.input("Comment: ")
      if comment and comment ~= "" then
        local patches = { { op = "add", path = "/fields/System.History", value = comment } }
        require("taskmeister.api").update_work_item(tonumber(id), patches)
        vim.notify("Added comment to WI" .. id)
      end
    elseif subcmd == "browser" then
      M.open_work_item_in_browser_by_id(args.fargs[2])
    elseif subcmd == "details" then
      M.fetch_and_show_work_item_details_by_id(args.fargs[2])
    elseif subcmd == "vt-show" then
      virt.show_work_item_virtual_text()
    elseif subcmd == "vt-clear" then
      virt.clear_current_buffer_virtual_text()
    else
      vim.notify("Unknown Taskmeister subcommand: " .. subcmd, vim.log.levels.ERROR)
    end
  end, {
    nargs = "+",
    desc = "Taskmeister command dispatcher",
    complete = function(arg_lead, cmd_line, _)
      local parts = vim.split(cmd_line, "%s+")
      if #parts <= 2 then
        local items = {}
        for name, _ in pairs(subcommands) do
          if vim.startswith(name, arg_lead) then
            table.insert(items, name)
          end
        end
        table.sort(items)
        return items
      end
      return {}
    end,
  })

    vim.api.nvim_create_autocmd("FileType", {
    pattern = "taskmeister",
    callback = function(args)
      local bufnr = args.buf
      vim.api.nvim_buf_set_keymap(bufnr, "n", "<leader>wc", "", {
        callback = function()
          local id = vim.b.taskmeister_work_item_id
          if id then
            local comment = vim.fn.input("Comment: ")
            if comment ~= "" then
              local patches = { { op = "add", path = "/fields/System.History", value = comment } }
              require("taskmeister.api").update_work_item(tonumber(id), patches)
              vim.notify("Added comment to WI" .. id)
              require("taskmeister.ui").open_work_item(tostring(id))
            end
          end
        end,
        desc = "Add comment",
      })
      vim.api.nvim_buf_set_keymap(bufnr, "n", "<leader>ws", "", {
        callback = function()
          local id = vim.b.taskmeister_work_item_id
          if id then
            local state = vim.fn.input("New State (e.g., Active, Resolved): ")
            if state ~= "" then
              local patches = { { op = "replace", path = "/fields/System.State", value = state } }
              require("taskmeister.api").update_work_item(tonumber(id), patches)
              vim.notify("Updated state for WI" .. id)
              require("taskmeister.ui").open_work_item(tostring(id))
            end
          end
        end,
        desc = "Change state",
      })
      vim.api.nvim_buf_set_keymap(bufnr, "n", "<leader>wa", "", {
        callback = function()
          local id = vim.b.taskmeister_work_item_id
          if id then
            local user = vim.fn.input("Assign to (email): ")
            if user ~= "" then
              local patches = { { op = "replace", path = "/fields/System.AssignedTo", value = user } }
              require("taskmeister.api").update_work_item(tonumber(id), patches)
              vim.notify("Assigned WI" .. id .. " to " .. user)
              require("taskmeister.ui").open_work_item(tostring(id))
            end
          end
        end,
        desc = "Assign user",
      })
      vim.api.nvim_buf_set_keymap(bufnr, "n", "<leader>rr", "", {
        callback = function()
          local id = vim.b.taskmeister_work_item_id
          if id then
            local reaction_type = vim.fn.input("Reaction type (thumbs_up, heart, etc.): ")
            local comment_id = vim.fn.input("Comment ID (from timeline revision): ")
            if reaction_type ~= "" and comment_id ~= "" then
              local success = require("taskmeister.api").add_comment_reaction(tonumber(id), tonumber(comment_id), reaction_type)
              if success then
                vim.notify("Added reaction " .. reaction_type .. " to comment " .. comment_id .. " in WI" .. id)
                require("taskmeister.ui").open_work_item(tostring(id))
              end
            end
          end
        end,
        desc = "Add reaction to comment",
      })
      vim.api.nvim_buf_set_keymap(bufnr, "n", ":w<CR>", "", {
        callback = function()
          require("taskmeister.ui").sync_buffer(bufnr)
        end,
        desc = "Sync work item",
      })
    end,
  })
  local config_module = require("taskmeister.config")
  local config = config_module.options or {}
  vim.api.nvim_set_hl(0, "TaskmeisterGreen", { fg = "#00CC6A" })
  vim.api.nvim_set_hl(0, "TaskmeisterPurple", { fg = "#C586C0" })
  vim.api.nvim_set_hl(0, "TaskmeisterBlue", { fg = "#0078D4" })
  vim.api.nvim_set_hl(0, "TaskmeisterComment", { fg = "#D7BA7D" }) -- New highlight for comments
  if not config.ui or not config.ui.use_signcolumn then
    vim.api.nvim_set_hl(0, "TaskmeisterSignColumn", { link = "Normal" })
  end
end

-- Function to format a single work item
function format_work_item(work_items)
  local lines = {}

  -- We assume we're formatting the first work item
  local work_item = work_items[1]

  -- Check if work_item and fields are valid
  if not work_item or not work_item.fields then
    return { "Invalid work item data" }
  end

  table.insert(lines, "Revision  Number: " .. tostring(work_item.rev))

  -- Display Work Item ID, Title, and other details
  table.insert(lines, "Work Item ID: " .. tostring(work_item.fields["System.Id"]))
  table.insert(lines, "Title: " .. (work_item.fields["System.Title"] or "No Title"))
  table.insert(lines, "State: " .. (work_item.fields["System.State"] or "No State"))

  -- Handle 'Assigned To' field with nested structure
  local assigned_to = work_item.fields["System.AssignedTo"]
  if assigned_to and assigned_to["displayName"] then
    table.insert(lines, "Assigned To: " .. assigned_to["displayName"])
  else
    table.insert(lines, "Assigned To: Unassigned")
  end

  -- Original Estimate (in hours)
  local original_estimate = work_item.fields["Microsoft.VSTS.Scheduling.OriginalEstimate"]
  if original_estimate then
    table.insert(lines, "Original Estimate: " .. tostring(original_estimate) .. " hours")
  else
    table.insert(lines, "Original Estimate: Not specified")
  end

  -- Completed Work (in hours)
  local completed_work = work_item.fields["Microsoft.VSTS.Scheduling.CompletedWork"]
  if completed_work then
    table.insert(lines, "Completed Work: " .. tostring(completed_work) .. " hours")
  else
    table.insert(lines, "Completed Work: Not specified")
  end

  -- Remaining Work (in hours)
  local remaining_work = work_item.fields["Microsoft.VSTS.Scheduling.RemainingWork"]
  if remaining_work then
    table.insert(lines, "Remaining Work: " .. tostring(remaining_work) .. " hours")
  else
    table.insert(lines, "Remaining Work: Not specified")
  end

  -- Description field
  table.insert(lines, "Description: " .. (work_item.fields["System.Description"] or "No description"))

  return lines
end

function show_virtual_text_below_word(work_items)
  -- We assume we're formatting the first work item
  local work_item = work_items[1]

  -- Prepare the virtual text content to be displayed below
  local virt_text = {}

  local bufnr = vim.api.nvim_get_current_buf()  -- Get the current buffer number
  local namespace_id = vim.api.nvim_create_namespace("work_item_details_overlay")  -- Create a namespace for the virtual text

  -- Get the current line for the word under the cursor
  local current_line = vim.fn.line('.') - 1  -- Current line number (0-based)

  -- Check if work_item and fields are valid
  if not work_item or not work_item.fields then
  table.insert(virt_text, { "Invalid work item data", "Comment" })
  vim.api.nvim_buf_set_extmark(bufnr, namespace_id, current_line + 1, 0, {
    virt_text = virt_text,       -- The virtual text content
    virt_text_pos = 'overlay',   -- Positioning like an overlay on the next line
    hl_mode = 'combine'          -- Combine virtual text highlighting with current syntax
  })
    return
  end

  -- Display Work Item ID, Title, and other details in the overlay
  table.insert(virt_text, { "Work Item ID: " .. tostring(work_item.fields["System.Id"]), "Comment" })
  table.insert(virt_text, { " | Title: " .. (work_item.fields["System.Title"] or "No Title"), "Comment" })
  table.insert(virt_text, { " | State: " .. (work_item.fields["System.State"] or "No State"), "Comment" })

  -- Handle 'Assigned To' field with nested structure
  local assigned_to = work_item.fields["System.AssignedTo"]
  if assigned_to and assigned_to["displayName"] then
    table.insert(virt_text, { " | Assigned To: " .. assigned_to["displayName"], "Comment" })
  else
    table.insert(virt_text, { " | Assigned To: Unassigned", "Comment" })
  end

  -- Original Estimate, Completed Work, Remaining Work
  local original_estimate = work_item.fields["Microsoft.VSTS.Scheduling.OriginalEstimate"]
  local completed_work = work_item.fields["Microsoft.VSTS.Scheduling.CompletedWork"]
  local remaining_work = work_item.fields["Microsoft.VSTS.Scheduling.RemainingWork"]

  table.insert(virt_text, { " | Original Estimate: " .. (tostring(original_estimate) or "Not specified") .. " hours", "Comment" })
  table.insert(virt_text, { " | Completed Work: " .. (tostring(completed_work) or "Not specified") .. " hours", "Comment" })
  table.insert(virt_text, { " | Remaining Work: " .. (tostring(remaining_work) or "Not specified") .. " hours", "Comment" })

  -- Place the virtual text on the line below the current word, starting from column 0
  vim.api.nvim_buf_set_extmark(bufnr, namespace_id, current_line + 1, 0, {
    virt_text = virt_text,       -- The virtual text content
    virt_text_pos = 'overlay',   -- Positioning like an overlay on the next line
    hl_mode = 'combine'          -- Combine virtual text highlighting with current syntax
  })
end

function format_work_item_for_editing_with_virtual_text(work_items)
  -- Buffer lines to hold only the editable content
  local lines = {}
  local ns_id = vim.api.nvim_create_namespace("work_item_labels")

  -- We assume we're formatting the first work item
  local work_item = work_items[1]

    -- Helper to safely get a field as a string
  local function safe_field(field)
    return field and tostring(field) or "" -- Convert to string or use an empty string
  end

    -- Insert only the values as editable content
  table.insert(lines, safe_field(work_item.fields["System.Id"]))
  table.insert(lines, safe_field(work_item.fields["System.Title"]))
  table.insert(lines, safe_field(work_item.fields["System.State"]))
  table.insert(lines, safe_field(work_item.fields["System.Description"]))

  -- Create the buffer for editing
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Add virtual text (labels) at the start of each line
  vim.api.nvim_buf_set_extmark(buf, ns_id, 0, 0, {
    virt_text = { { "Work Item ID: ", "Comment" } },
    virt_text_pos = "overlay"
  })
  vim.api.nvim_buf_set_extmark(buf, ns_id, 1, 0, {
    virt_text = { { "Title: ", "Comment" } },
    virt_text_pos = "overlay"
  })
  vim.api.nvim_buf_set_extmark(buf, ns_id, 2, 0, {
    virt_text = { { "State: ", "Comment" } },
    virt_text_pos = "overlay"
  })
  vim.api.nvim_buf_set_extmark(buf, ns_id, 3, 0, {
    virt_text = { { "Description: ", "Comment" } },
    virt_text_pos = "overlay"
  })

  return buf
end

return M
