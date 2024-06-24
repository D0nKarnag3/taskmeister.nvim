local config = require('azure_devops.config')
local Job = require('plenary.job')

local api = {}


function api.get_workitem_type_and_title(wi_ids, callback)
  local opts = config.options

  if not opts.personal_access_token or not opts.organization or not opts.project then
    print("Please configure the plugin with PAT, organization, and project")
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
      --callback(job:result())
    end
  }):start()
end

return api
