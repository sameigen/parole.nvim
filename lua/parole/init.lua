---@class parole.AgentProfile
---@field cmd string[] base command, e.g. { "claude" }
---@field headless string[]? extra flags for headless dispatch
---@field yolo_flags string[]? flags that disable permission checks entirely
---@field auto_flags string[]? flags for the agent's auto-accept mode

---@class parole.AgentConfig
---@field use string which profile dispatches (key into profiles)
---@field yolo boolean run agents with ALL permission checks off (off by default; pull deliberately)
---@field auto boolean run agents in their auto-accept mode (off by default)
---@field profiles table<string, parole.AgentProfile> named agent harnesses (claude, codex, ...)

---@class parole.KeymapsConfig
---@field board table<string, string|false> action -> lhs for board buffers; false disables
---@field case table<string, string|false> action -> lhs for case buffers; false disables
---@field diff table<string, string|false> action -> lhs for quick-diff buffers; false disables

---@class parole.Config
---@field owners string[] GitHub owners (orgs/users) to scope searches to; empty = anywhere you're involved
---@field roots string[] directories scanned (2 levels deep) for local clones
---@field worktree_dir string where parole-managed worktrees live
---@field refresh_interval integer seconds between board auto-refreshes (0 disables)
---@field limit integer max PRs fetched per board section
---@field agent parole.AgentConfig
---@field keymaps parole.KeymapsConfig

local M = {}

---@type parole.Config
M.defaults = {
  owners = {},
  roots = { "~/Code" },
  worktree_dir = vim.fn.stdpath("cache") .. "/parole/worktrees",
  refresh_interval = 300,
  limit = 50,
  agent = {
    use = "claude",
    yolo = false,
    auto = false,
    profiles = {
      claude = {
        cmd = { "claude" },
        headless = { "-p", "--output-format", "text" },
        yolo_flags = { "--dangerously-skip-permissions" },
        auto_flags = { "--permission-mode", "auto" },
      },
    },
  },
  keymaps = {
    board = {
      open_case = "<CR>",
      diff = "v",
      octo = "o",
      deep_review = "D",
      agent = "a",
      agent_headless = "A",
      browse = "gx",
      hover = "K",
      expunge = "X",
      refresh = "r",
      close = "q",
      help = "?",
    },
    case = {
      approve = "a",
      request_changes = "x",
      comment = "c",
      reply = "R",
      diff = "v",
      deep_review = "D",
      octo = "o",
      browse = "gx",
      goto_file = "gf",
      refresh = "r",
      close = "q",
      help = "?",
    },
    diff = {
      comment = "c",
      goto_file = "gf",
      close = "q",
      help = "?",
    },
  },
}

---@type parole.Config
M.config = vim.deepcopy(M.defaults)

---@param opts table
local function validate(opts)
  local function fail(msg)
    error("parole.setup: " .. msg, 3)
  end
  local function check_list(name, v, item_type)
    if v == nil then
      return
    end
    if not vim.islist(v) then
      fail(("`%s` must be a list of %ss"):format(name, item_type))
    end
    for _, item in ipairs(v) do
      if type(item) ~= item_type then
        fail(("`%s` must contain only %ss"):format(name, item_type))
      end
    end
  end
  check_list("owners", opts.owners, "string")
  check_list("roots", opts.roots, "string")
  if opts.worktree_dir ~= nil and type(opts.worktree_dir) ~= "string" then
    fail("`worktree_dir` must be a string")
  end
  if opts.refresh_interval ~= nil and (type(opts.refresh_interval) ~= "number" or opts.refresh_interval < 0) then
    fail("`refresh_interval` must be a non-negative number")
  end
  if opts.limit ~= nil and (type(opts.limit) ~= "number" or opts.limit < 1) then
    fail("`limit` must be a positive number")
  end
  if opts.agent ~= nil then
    for _, lever in ipairs({ "yolo", "auto" }) do
      if opts.agent[lever] ~= nil and type(opts.agent[lever]) ~= "boolean" then
        fail(("`agent.%s` must be a boolean"):format(lever))
      end
    end
    if opts.agent.use ~= nil and type(opts.agent.use) ~= "string" then
      fail("`agent.use` must be a string naming a profile")
    end
    if opts.agent.profiles ~= nil then
      if type(opts.agent.profiles) ~= "table" then
        fail("`agent.profiles` must be a table")
      end
      for name, profile in pairs(opts.agent.profiles) do
        check_list(("agent.profiles.%s.cmd"):format(name), profile.cmd, "string")
        if profile.cmd ~= nil and #profile.cmd == 0 then
          fail(("`agent.profiles.%s.cmd` must not be empty"):format(name))
        end
        for _, flags in ipairs({ "headless", "yolo_flags", "auto_flags" }) do
          check_list(("agent.profiles.%s.%s"):format(name, flags), profile[flags], "string")
        end
      end
    end
    local use = opts.agent.use or M.defaults.agent.use
    local profiles = vim.tbl_extend("force", M.defaults.agent.profiles, opts.agent.profiles or {})
    if not profiles[use] then
      fail(("`agent.use` names unknown profile %q"):format(use))
    end
  end
  if opts.keymaps ~= nil then
    local known = require("parole.keys").descriptions
    for _, scope in ipairs({ "board", "case", "diff" }) do
      local maps = opts.keymaps[scope]
      if maps ~= nil then
        if type(maps) ~= "table" then
          fail(("`keymaps.%s` must be a table"):format(scope))
        end
        for action, lhs in pairs(maps) do
          if not known[action] or M.defaults.keymaps[scope][action] == nil then
            fail(("`keymaps.%s.%s` is not a known action"):format(scope, action))
          end
          if lhs ~= false and type(lhs) ~= "string" then
            fail(("`keymaps.%s.%s` must be a string or false"):format(scope, action))
          end
        end
      end
    end
  end
end

---@param opts? parole.Config partial config, merged over defaults
function M.setup(opts)
  opts = opts or {}
  validate(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
end

---Parse a PR reference out of a URL, "owner/repo#123", or "owner/repo 123".
---@param arg string
---@return string? owner, string? repo, integer? number
function M.parse_pr_arg(arg)
  local owner, repo, num = arg:match("github%.com/([^/]+)/([^/]+)/pull/(%d+)")
  if not owner then
    owner, repo, num = arg:match("^([^/%s]+)/([^/#%s]+)#(%d+)$")
  end
  if not owner then
    owner, repo, num = arg:match("^([^/%s]+)/([^/%s]+)%s+(%d+)$")
  end
  if owner then
    return owner, repo, tonumber(num)
  end
end

---Entry point for :Parole — no arg opens the board, an arg opens that case.
---@param arg? string
function M.open(arg)
  if not arg or arg == "" then
    require("parole.board").open()
    return
  end
  local owner, repo, number = M.parse_pr_arg(arg)
  if not owner then
    vim.notify("parole: could not parse PR reference: " .. arg, vim.log.levels.ERROR)
    return
  end
  require("parole.case").open(owner, repo, number)
end

return M
