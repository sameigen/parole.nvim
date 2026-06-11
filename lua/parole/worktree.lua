---Worktree management: materialise a PR (or a fresh branch) as a real
---checkout so LSP, fugitive, and agents get an honest working tree.
local M = {}

---@param args string[]
---@param cwd string?
---@param cb fun(err: string?, stdout: string?)
local function git(args, cwd, cb)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true, cwd = cwd }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        cb(vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or ("git exited " .. res.code))
      else
        cb(nil, res.stdout)
      end
    end)
  end)
end

---@param pr parole.Pr
---@return string
local function worktree_path(pr)
  local root = require("parole").config.worktree_dir
  return ("%s/%s__%s__pr-%d"):format(root, pr.owner, pr.repo, pr.number)
end

---Create (or reuse) a worktree for a PR. Calls back with its path.
---@param pr parole.Pr
---@param cb fun(path: string?, clone: string?)
function M.ensure(pr, cb)
  local clone = require("parole.repos").find(pr.owner, pr.repo)
  if not clone then
    vim.notify(
      ("parole: no local clone of %s found under configured roots — clone it first (gh repo clone %s)"):format(
        pr.slug,
        pr.slug
      ),
      vim.log.levels.ERROR
    )
    return cb(nil)
  end

  local path = worktree_path(pr)
  if vim.uv.fs_stat(path .. "/.git") then
    return cb(path, clone)
  end

  vim.fn.mkdir(require("parole").config.worktree_dir, "p")
  local branch = ("parole/pr-%d"):format(pr.number)
  vim.notify(("parole: fetching %s#%d…"):format(pr.slug, pr.number))
  git({ "fetch", "origin", ("+refs/pull/%d/head:refs/heads/%s"):format(pr.number, branch) }, clone, function(err)
    if err then
      vim.notify("parole: fetch failed: " .. err, vim.log.levels.ERROR)
      return cb(nil)
    end
    git({ "worktree", "add", path, branch }, clone, function(wt_err)
      if wt_err then
        vim.notify("parole: worktree add failed: " .. wt_err, vim.log.levels.ERROR)
        return cb(nil)
      end
      -- base ref is needed for merge-base diffs; fetch is best-effort
      if pr.base then
        git({ "fetch", "origin", pr.base }, clone, function() end)
      end
      cb(path, clone)
    end)
  end)
end

---Deep review: worktree + diffview (or fugitive) against the merge base.
---@param pr parole.Pr
function M.review(pr)
  local function go()
    M.ensure(pr, function(path)
      if not path then
        return
      end
      if pcall(require, "diffview") then
        -- diffview opens its own tab; -C points it at the worktree.
        -- :DiffviewClose (or q, if mapped) drops you back where you were.
        vim.cmd(("DiffviewOpen -C%s origin/%s...HEAD"):format(vim.fn.fnameescape(path), pr.base))
      else
        vim.cmd.tabnew()
        vim.cmd.tcd(vim.fn.fnameescape(path))
        vim.cmd(("Git diff origin/%s...HEAD"):format(pr.base))
      end
    end)
  end
  if pr.base then
    return go()
  end
  require("parole.gh").json(
    { "pr", "view", tostring(pr.number), "--repo", pr.slug, "--json", "baseRefName" },
    function(err, data)
      if err or not data then
        return vim.notify("parole: could not resolve base branch", vim.log.levels.ERROR)
      end
      pr.base = data.baseRefName
      go()
    end
  )
end

---@return { name: string, path: string }[] directories under worktree_dir
local function managed_dirs()
  local root = require("parole").config.worktree_dir
  local dirs = {}
  local handle = vim.uv.fs_scandir(root)
  while handle do
    local name, type_ = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if type_ == "directory" then
      table.insert(dirs, { name = name, path = root .. "/" .. name })
    end
  end
  return dirs
end

---Remove one managed worktree. Refuses dirty trees unless forced.
---@param path string
---@param force boolean
---@return "removed"|"dirty"|"failed"
local function remove_one(path, force)
  local common = vim
    .system({ "git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir" }, { text = true })
    :wait()
  local clone = common.code == 0 and vim.fs.dirname(vim.trim(common.stdout)) or nil
  if not clone or clone == path then
    return "failed"
  end
  if not force then
    local status = vim.system({ "git", "-C", path, "status", "--porcelain" }, { text = true }):wait()
    if status.code == 0 and vim.trim(status.stdout or "") ~= "" then
      return "dirty"
    end
  end
  local branch_res = vim.system({ "git", "-C", path, "branch", "--show-current" }, { text = true }):wait()
  local branch = vim.trim(branch_res.stdout or "")
  local res = vim.system({ "git", "-C", clone, "worktree", "remove", "--force", path }, { text = true }):wait()
  if res.code ~= 0 then
    return "failed"
  end
  if branch:match("^parole/pr%-%d+$") then
    vim.system({ "git", "-C", clone, "branch", "-D", branch }, { text = true }):wait()
  end
  return "removed"
end

---Remove all parole-managed worktrees. Dirty trees are skipped unless
---force; PR branches (`parole/pr-N`) are deleted, agent branches kept —
---they may hold the agent's commits.
---@param opts? { force: boolean }
function M.clean(opts)
  opts = opts or {}
  local dirs = managed_dirs()
  if #dirs == 0 then
    vim.notify("parole: no worktrees to clean")
    return
  end
  local removed, dirty = 0, {}
  for _, dir in ipairs(dirs) do
    local result = remove_one(dir.path, opts.force or false)
    if result == "removed" then
      removed = removed + 1
    elseif result == "dirty" then
      table.insert(dirty, dir.name)
    end
  end
  local msg = ("parole: removed %d worktree(s)"):format(removed)
  if #dirty > 0 then
    msg = msg .. (" — skipped %d with uncommitted changes (:ParoleClean! to force)"):format(#dirty)
  end
  vim.notify(msg)
end

---Remove a single managed worktree by path (public wrapper).
---@param path string
---@param force boolean
---@return "removed"|"dirty"|"failed"
function M.remove(path, force)
  return remove_one(path, force)
end

local sweep_done = false

---Background sweep: remove worktrees whose PR is merged or closed.
---Dirty trees are kept. Runs at most once per session (board open).
function M.sweep()
  if sweep_done then
    return
  end
  sweep_done = true
  local gh = require("parole.gh")
  local jobs = {}
  local removed = 0
  for _, dir in ipairs(managed_dirs()) do
    local owner, repo, number = dir.name:match("^([^_]+)__(.+)__pr%-(%d+)$")
    if owner then
      table.insert(jobs, function(done)
        gh.json({ "pr", "view", number, "--repo", owner .. "/" .. repo, "--json", "state" }, function(err, data)
          if not err and data and data.state ~= "OPEN" then
            if remove_one(dir.path, false) == "removed" then
              removed = removed + 1
            end
          end
          done()
        end)
      end)
    end
  end
  if #jobs == 0 then
    return
  end
  local pending = #jobs
  local wrapped = {}
  for _, job in ipairs(jobs) do
    table.insert(wrapped, function(done)
      job(function()
        pending = pending - 1
        if pending == 0 and removed > 0 then
          vim.notify(("parole: swept %d worktree(s) for merged/closed PRs"):format(removed))
        end
        done()
      end)
    end)
  end
  gh.pool(wrapped, 4)
end

---Create a scratch worktree off the current repo's HEAD (for agent runs).
---@param clone string repo path
---@param branch string new branch name
---@param cb fun(path: string?)
function M.scratch(clone, branch, cb)
  local root = require("parole").config.worktree_dir
  vim.fn.mkdir(root, "p")
  local dirname = vim.fs.basename(clone)
  local path = ("%s/%s__agent-%s"):format(root, dirname, branch:gsub("[^%w%-_]", "-"))
  if vim.uv.fs_stat(path .. "/.git") then
    return cb(path)
  end
  git({ "worktree", "add", "-b", branch, path }, clone, function(err)
    if err then
      vim.notify("parole: worktree add failed: " .. err, vim.log.levels.ERROR)
      return cb(nil)
    end
    cb(path)
  end)
end

return M
