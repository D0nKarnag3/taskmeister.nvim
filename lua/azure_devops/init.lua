local config = require('azure_devops.config')
local Job = require('plenary.job')
local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local previewers = require('telescope.previewers')
local api = require('azure_devops.api')

local M = {}

function M.setup(opts)
  config.set(opts)
  M.register()
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

function M.register()
  vim.api.nvim_create_user_command(
    'AzureShowWorkItemVirtualText',
    function()
      virt.show_work_item_virtual_text()
    end,
    {
      nargs = 0,  -- The command expects exactly one argument (the work item ID)
      desc = "Fetch and display virtual text for Azure DevOps Work Items"
    }
  )

  vim.api.nvim_create_user_command(
    'AzureClearWorkItemVirtualText',
    function()
      local bufnr = vim.api.nvim_get_current_buf() -- Temp
      local namespace_id = vim.api.nvim_create_namespace('virtual_text_matcher') -- Temp
      virt.clear_virtual_text(bufnr, namespace_id)
    end,
    {
      nargs = 0,  -- The command expects exactly one argument (the work item ID)
      desc = "Fetch and display virtual text for Azure DevOps Work Items"
    }
  )

  vim.api.nvim_create_user_command(
    'AzureOpenWorkItemInBrowser',
    function()
        M.open_work_item_in_browser();
    end,
    {
      nargs = 0,
      desc = "Open Azure DevOps Work Item in a browser"
    }
  )
end

return M
