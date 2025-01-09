local config = require('taskmeister.config')
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
    end
  }):start()
end

function api.get_workitem_type_and_title2(wi_ids, fields_to_fetch, callback)
  local opts = config.options

  if not opts.personal_access_token or not opts.organization or not opts.project then
    print("Please configure the plugin with PAT, organization, and project")
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

function api.update_workitem(work_item, callback)
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

return api
