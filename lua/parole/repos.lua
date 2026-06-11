---Discovery of local clones: maps "owner/repo" -> absolute path by scanning
---configured roots two levels deep and reading each repo's origin URL.
local M = {}

---@type table<string, string>?
local cache = nil

---@param url string a git remote URL
---@return string? slug "owner/repo"
local function slug_from_url(url)
  local owner, repo = url:match("github%.com[:/]([^/]+)/([^/%s]+)")
  if not owner then
    return nil
  end
  repo = repo:gsub("%.git$", "")
  return (owner .. "/" .. repo):lower()
end

---@param dir string
---@return string? slug
local function origin_slug(dir)
  local res = vim.system({ "git", "-C", dir, "remote", "get-url", "origin" }, { text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  return slug_from_url(vim.trim(res.stdout or ""))
end

---@param dir string
---@param depth integer
---@param found table<string, string>
local function scan(dir, depth, found)
  if vim.uv.fs_stat(dir .. "/.git") then
    local slug = origin_slug(dir)
    if slug and not found[slug] then
      found[slug] = dir
    end
    return
  end
  if depth <= 0 then
    return
  end
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return
  end
  while true do
    local name, type_ = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if type_ == "directory" and not name:match("^%.") then
      scan(dir .. "/" .. name, depth - 1, found)
    end
  end
end

---@param refresh? boolean force a rescan
---@return table<string, string> map of "owner/repo" -> path
function M.all(refresh)
  if cache and not refresh then
    return cache
  end
  local found = {}
  for _, root in ipairs(require("parole").config.roots) do
    scan(vim.fs.normalize(vim.fn.expand(root)), 2, found)
  end
  cache = found
  return found
end

---@param owner string
---@param repo string
---@return string? path local clone path, if one exists
function M.find(owner, repo)
  local slug = (owner .. "/" .. repo):lower()
  local path = M.all()[slug]
  if path then
    return path
  end
  return M.all(true)[slug]
end

return M
