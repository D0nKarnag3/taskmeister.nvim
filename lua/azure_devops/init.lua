local config = require('azure_devops.config')
local Job = require('plenary.job')
local fzf = require('fzf-lua')

local M = {}

function M.setup(opts)
  config.set(opts)
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
                    local items = {}
                    for _, item in ipairs(result.value) do
                      table.insert(items, string.format("%s\t%d:%s", item.fields["System.WorkItemType"], item.id, item.fields["System.Title"]))
                    end
                    fzf.fzf_exec(items, {
                      prompt = 'Work Item > ',
                      actions = {
                        ['default'] = function(selected)
                          local work_item_id = selected[1]:match("^(%d+):")
                          print("Selected Work Item ID: " .. work_item_id)
                        end
                      }
                    })
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

return M
