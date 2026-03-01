local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local api = require("taskmeister.api")
local config = require("taskmeister.config").get()

local M = {}

local function get_icon(type)
  if not config.show_work_item_icon then return "" end
  local icons = {
    Task = "󰗀 ",
    Bug = "󰨰 ",
    Feature = "󰉗 ",
  }
  return icons[type] or ""
end

local function build_wiql(opts)
  local wiql = "SELECT [System.Id] FROM workitems WHERE [System.TeamProject] = @project"
  if opts.search then
    wiql = wiql .. " AND [System.Title] CONTAINS '" .. opts.search:gsub("'", "''") .. "'"
  end
  if opts.type then
    wiql = wiql .. " AND [System.WorkItemType] = '" .. opts.type .. "'"
  end
  if opts.id then
    wiql = wiql .. " AND [System.Id] = " .. opts.id
  end
  return wiql
end

function M.work_items(opts)
  opts = opts or {}
  local wiql = build_wiql(opts)
  local ids = api.query_work_item_ids(wiql)
  local work_items = api.get_work_items_batch(ids)

  pickers
    .new(opts, {
      prompt_title = "Taskmeister Work Items" .. (opts.search and " (Search: " .. opts.search .. ")" or ""),
      finder = finders.new_table({
        results = work_items,
        entry_maker = function(entry)
          local fields = entry.fields
          local display = get_icon(fields["System.WorkItemType"])
            .. "WI" .. fields["System.Id"]
            .. " "
            .. fields["System.Title"]
            .. " ("
            .. fields["System.State"]
            .. ", Assigned: "
            .. (fields["System.AssignedTo"] and fields["System.AssignedTo"].displayName or "Unassigned")
            .. ")"
          return {
            value = entry,
            display = display,
            ordinal = display,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = conf.grep_previewer(opts), -- Could customize for description/history
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry().value
          require("taskmeister.ui").open_work_item(selection.id)
        end)

        map("i", "<C-o>", function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry().value
          require("taskmeister.ui").open_work_item(selection.id)
        end, { desc = "Open work item in buffer" })

        map("i", "<C-c>", function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry().value
          local comment = vim.fn.input("Comment: ")
          if comment ~= "" then
            local patches = { { op = "add", path = "/fields/System.History", value = comment } }
            api.update_work_item(selection.id, patches)
            vim.notify("Comment added to WI" .. selection.id)
          end
        end, { desc = "Add comment" })

        map("i", "<C-s>", function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry().value
          local state = vim.fn.input("New State (e.g., Active, Resolved): ")
          if state ~= "" then
            local patches = { { op = "replace", path = "/fields/System.State", value = state } }
            api.update_work_item(selection.id, patches)
            vim.notify("State changed to " .. state .. " for WI" .. selection.id)
          end
        end, { desc = "Change state" })

        map("i", "<C-a>", function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry().value
          local email = vim.fn.input("Assign to (email): ")
          if email ~= "" then
            local patches = { { op = "replace", path = "/fields/System.AssignedTo", value = email } }
            api.update_work_item(selection.id, patches)
            vim.notify("Assigned WI" .. selection.id .. " to " .. email)
          end
        end, { desc = "Assign user" })

        map("i", "<C-b>", function()
          local selection = action_state.get_selected_entry().value
          local url = "https://dev.azure.com/" .. config.organization .. "/" .. config.project .. "/_workitems/edit/" .. selection.id
          vim.fn.system({ "xdg-open", url }) -- Or use plenary.job for cross-platform
          vim.notify("Opened WI" .. selection.id .. " in browser")
        end, { desc = "Open in browser" })

        return true
      end,
    })
    :find()
end

return require("telescope").register_extension({
  exports = { work_items = M.work_items },
})
