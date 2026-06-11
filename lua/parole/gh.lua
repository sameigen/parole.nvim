---Thin async wrapper around the `gh` CLI. All callbacks run on the main loop.
local M = {}

---@param args string[] arguments passed to gh
---@param cb fun(err: string?, stdout: string?)
---@param opts? { cwd?: string }
function M.run(args, cb, opts)
  opts = opts or {}
  local cmd = { "gh" }
  vim.list_extend(cmd, args)
  local ok, err = pcall(vim.system, cmd, { text = true, cwd = opts.cwd }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        local msg = (res.stderr and res.stderr ~= "") and vim.trim(res.stderr) or ("gh exited with code " .. res.code)
        cb(msg)
      else
        cb(nil, res.stdout or "")
      end
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb("failed to spawn gh: " .. tostring(err))
    end)
  end
end

---Run gh and decode stdout as JSON.
---@param args string[]
---@param cb fun(err: string?, data: any)
function M.json(args, cb)
  M.run(args, function(err, out)
    if err then
      return cb(err)
    end
    local ok, data = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
    if not ok then
      return cb("could not decode gh output: " .. tostring(data))
    end
    cb(nil, data)
  end)
end

---Run a GraphQL query via `gh api graphql`.
---@param query string
---@param vars table<string, string|integer>
---@param cb fun(err: string?, data: any)
function M.graphql(query, vars, cb)
  local args = { "api", "graphql", "-f", "query=" .. query }
  for k, v in pairs(vars) do
    if type(v) == "number" then
      table.insert(args, "-F")
    else
      table.insert(args, "-f")
    end
    table.insert(args, k .. "=" .. tostring(v))
  end
  M.json(args, cb)
end

---Run several async jobs with bounded concurrency.
---@param jobs (fun(done: fun()))[]
---@param max_concurrent integer
function M.pool(jobs, max_concurrent)
  local next_job = 1
  local function spawn()
    local job = jobs[next_job]
    if not job then
      return
    end
    next_job = next_job + 1
    job(spawn)
  end
  for _ = 1, math.min(max_concurrent, #jobs) do
    spawn()
  end
end

return M
