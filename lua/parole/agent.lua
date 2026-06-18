---Agent dispatch: materialise a worktree, collect the context you want the
---agent preloaded with, then drop into the configured agent harness —
---interactive in a terminal buffer, or headless.
---
---Dispatched sessions are tracked; the board renders them as AGENTS ON DUTY
---so you can jump in and out while reviewing other PRs.
local util = require("parole.util")

local M = {}

---@class parole.AgentSession
---@field buf integer terminal buffer
---@field title string e.g. "acme/widgets#42"
---@field path string worktree the agent runs in
---@field headless boolean
---@field status "running"|string "running" or "exited (N)"
---@field started integer epoch seconds
---@field record string? path of the persisted report once finished

---@type parole.AgentSession[]
local sessions = {}

local HISTORY_KEEP = 50

-- POSIX-family shells that accept `-lc '<posix command>'` (login_argv).
M._POSIX_SHELLS = { sh = true, bash = true, zsh = true, dash = true, ksh = true, mksh = true, ash = true }

-- Printed by a headless login shell after its profile has run, so the capture
-- can discard profile chatter and keep only the agent's own output.
M.OUTPUT_MARK = "__parole_agent_output_8f3a__"

---Wrap an agent argv to run under a login shell, so it sources the user's
---profile (~/.zshenv / ~/.zprofile): the agent's auth token (CLAUDE_CODE_OAUTH_TOKEN)
---and PATH. Without this, an agent dispatched from a GUI-launched nvim can't reach
---the macOS keychain (locked outside a GUI session) and hard-blocks on /login at the
---first message. Quote-safe. Exposed for tests.
---
---opts.sentinel: emit this marker line before the agent command. A caller that
---captures stdout (headless) can then drop everything up to the marker, so a
---noisy login profile (banners, version managers) can't corrupt the report.
---@param cmd string[]
---@param opts {sentinel?: string}|nil
---@return string[]
function M.login_argv(cmd, opts)
  opts = opts or {}
  local function shq(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
  end
  local joined = table.concat(vim.tbl_map(shq, cmd), " ")
  if opts.sentinel then
    joined = ("printf '%%s\\n' %s; "):format(shq(opts.sentinel)) .. joined
  end
  -- Use $SHELL so the user's profile (and token) are sourced — but only when it
  -- is a POSIX-family shell. fish/csh/nu reject `-lc '<posix>'` outright, so fall
  -- back to /bin/sh for them rather than break dispatch entirely.
  local shell = os.getenv("SHELL") or ""
  local base = shell:match("[^/]+$") or ""
  if not M._POSIX_SHELLS[base] then
    shell = "/bin/sh"
  end
  return { shell, "-lc", joined }
end

local function history_dir()
  return vim.fn.stdpath("state") .. "/parole/agents"
end

---Persist a finished session to disk so it survives nvim restarts.
---@param session parole.AgentSession
---@param output string[] the agent's output (report or terminal scrollback)
---@param code integer
local function record(session, output, code)
  local dir = history_dir()
  vim.fn.mkdir(dir, "p")
  local slug = session.title:gsub("[^%w%-#@%.]", "_")
  local file = ("%s/%s-%s.md"):format(dir, os.date("%Y%m%d-%H%M%S"), slug)
  local lines = {
    "# Agent report — " .. session.title,
    "",
    "- mode: " .. (session.headless and "headless" or "interactive"),
    "- exit: " .. code,
    "- worktree: " .. session.path,
    "- finished: " .. os.date("%Y-%m-%dT%H:%M:%S"),
    "",
  }
  vim.list_extend(lines, #output > 0 and output or { "_no output captured_" })
  vim.fn.writefile(lines, file)
  session.record = file

  -- prune the oldest records past the cap
  local files = vim.fn.glob(dir .. "/*.md", false, true)
  table.sort(files)
  for i = 1, #files - HISTORY_KEEP do
    vim.fn.delete(files[i])
  end
end

---@class parole.AgentRecord
---@field file string
---@field title string
---@field mode string
---@field exit integer?
---@field mtime integer

---Finished sessions persisted on disk, newest first.
---@return parole.AgentRecord[]
function M.history()
  local out = {}
  local live = {}
  for _, s in ipairs(M.list()) do
    if s.record then
      live[s.record] = true
    end
  end
  local files = vim.fn.glob(history_dir() .. "/*.md", false, true)
  table.sort(files, function(a, b)
    return a > b
  end)
  for _, file in ipairs(files) do
    if not live[file] then
      local head = vim.fn.readfile(file, "", 8)
      local entry = {
        file = file,
        title = (head[1] or ""):match("^# Agent report — (.+)$") or vim.fs.basename(file),
        mode = "?",
        mtime = (vim.uv.fs_stat(file) or {}).mtime and vim.uv.fs_stat(file).mtime.sec or 0,
      }
      for _, l in ipairs(head) do
        entry.mode = l:match("^%- mode: (.+)$") or entry.mode
        entry.exit = tonumber(l:match("^%- exit: (%d+)$")) or entry.exit
        entry.worktree = l:match("^%- worktree: (.+)$") or entry.worktree
      end
      table.insert(out, entry)
    end
  end
  return out
end

---Permanently remove a record: its output file and, on request, its worktree.
---@param entry parole.AgentRecord
---@param after? fun()
function M.expunge(entry, after)
  local has_worktree = entry.worktree and vim.uv.fs_stat(entry.worktree) ~= nil
  local choice = 1
  if has_worktree then
    choice = vim.fn.confirm(
      ("Expunge %s — also remove its worktree?\n%s"):format(entry.title, entry.worktree),
      "&Record only\n&Both\n&Cancel",
      1
    )
  end
  if choice == 0 or choice == 3 then
    return
  end
  if choice == 2 then
    local result = require("parole.worktree").remove(entry.worktree, false)
    if result == "dirty" then
      vim.notify("parole: worktree has uncommitted changes — kept (use :ParoleClean! to force)", vim.log.levels.WARN)
    end
  end
  if entry.file then
    vim.fn.delete(entry.file)
  end
  vim.notify("parole: expunged " .. entry.title)
  if after then
    after()
  end
end

---@return parole.AgentProfile profile, string name
local function profile()
  local agent = require("parole").config.agent
  return agent.profiles[agent.use], agent.use
end

---Build the full command for a dispatch, applying the configured levers.
---Exposed for tests.
---@param opts { headless: boolean }
---@param prompt string
---@return string[]
function M.build_cmd(opts, prompt)
  local agent = require("parole").config.agent
  local prof, name = profile()
  local cmd = vim.deepcopy(prof.cmd)
  if agent.yolo then
    if prof.yolo_flags then
      vim.list_extend(cmd, prof.yolo_flags)
    else
      vim.notify(("parole: profile %q has no yolo_flags; lever ignored"):format(name), vim.log.levels.WARN)
    end
  end
  if agent.auto and not agent.yolo then -- yolo supersedes auto
    if prof.auto_flags then
      vim.list_extend(cmd, prof.auto_flags)
    else
      vim.notify(("parole: profile %q has no auto_flags; lever ignored"):format(name), vim.log.levels.WARN)
    end
  end
  if opts.headless and prof.headless then
    vim.list_extend(cmd, prof.headless)
  end
  table.insert(cmd, prompt)
  return cmd
end

---Live sessions (dead buffers pruned).
---@return parole.AgentSession[]
function M.list()
  sessions = vim.tbl_filter(function(s)
    return vim.api.nvim_buf_is_valid(s.buf)
  end, sessions)
  return sessions
end

---Bring a session's terminal into view: jump to its window if one exists,
---otherwise open it in a new tab.
---@param session parole.AgentSession
function M.focus(session)
  if not vim.api.nvim_buf_is_valid(session.buf) then
    return vim.notify("parole: that agent buffer is gone", vim.log.levels.WARN)
  end
  local wins = vim.fn.win_findbuf(session.buf)
  if #wins > 0 then
    vim.api.nvim_set_current_win(wins[1])
  else
    vim.cmd.tabnew()
    vim.api.nvim_win_set_buf(0, session.buf)
  end
end

local function redraw_board()
  pcall(function()
    require("parole.board").redraw()
  end)
end

---Headless: no tab, no terminal — run in the background, stream output into
---a report buffer, notify on completion. Read it from AGENTS ON DUTY.
---@param path string
---@param prompt string
---@param opts { title: string }
---@param session parole.AgentSession
local function launch_headless(path, prompt, opts, session)
  local cmd = M.build_cmd({ headless = true }, prompt)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "parole://report/" .. opts.title)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Agent report — " .. opts.title, "", "_working…_" })
  session.buf = buf

  local out, err_out = {}, {}
  local function collect(acc)
    return function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then
          table.insert(acc, line)
        end
      end
    end
  end
  -- Drop login-shell profile chatter: keep stdout only after the sentinel line.
  local seen_mark = false
  local function on_stdout(_, data)
    for _, line in ipairs(data or {}) do
      if not seen_mark then
        if line:find(M.OUTPUT_MARK, 1, true) then
          seen_mark = true
        end
      elseif line ~= "" then
        table.insert(out, line)
      end
    end
  end
  vim.fn.jobstart(M.login_argv(cmd, { sentinel = M.OUTPUT_MARK }), {
    cwd = path,
    on_stdout = on_stdout,
    on_stderr = collect(err_out),
    on_exit = function(_, code)
      vim.schedule(function()
        session.status = ("exited (%d)"):format(code)
        local report = vim.deepcopy(out)
        if #err_out > 0 and code ~= 0 then
          table.insert(report, "")
          table.insert(report, "## stderr")
          vim.list_extend(report, err_out)
        end
        record(session, report, code)
        if vim.api.nvim_buf_is_valid(buf) then
          local lines = { "# Agent report — " .. opts.title, "" }
          vim.list_extend(lines, #report > 0 and report or { "_no output_" })
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        end
        local level = code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
        vim.notify(
          ("parole: agent finished %s (exit %d) — <CR> on the board to read"):format(opts.title, code),
          level
        )
        redraw_board()
      end)
    end,
  })
  vim.notify("parole: headless agent dispatched for " .. opts.title .. " — it reports back to the board")
  redraw_board()
end

---@param path string worktree to run in
---@param prompt string
---@param opts { headless: boolean, title: string }
local function launch(path, prompt, opts)
  local session = {
    buf = -1,
    title = opts.title,
    path = path,
    headless = opts.headless or false,
    status = "running",
    started = os.time(),
  }
  table.insert(sessions, session)

  if opts.headless then
    return launch_headless(path, prompt, opts, session)
  end

  local cmd = M.build_cmd(opts, prompt)
  vim.cmd.tabnew()
  local buf = vim.api.nvim_get_current_buf()
  session.buf = buf

  -- agent TUIs (Claude Code) need Esc themselves (interrupt, Esc-Esc rewind):
  -- pass it through in this buffer, overriding any global t-mode Esc mapping.
  -- <C-\><C-n> leaves terminal mode; <C-q> is a convenient alias.
  vim.keymap.set("t", "<Esc>", "<Esc>", { buffer = buf, desc = "parole: Esc belongs to the agent" })
  vim.keymap.set("t", "<C-q>", "<C-\\><C-n>", { buffer = buf, desc = "parole: leave terminal mode" })
  for _, dir in ipairs({ "h", "j", "k", "l" }) do
    vim.keymap.set("t", "<C-" .. dir .. ">", "<Cmd>wincmd " .. dir .. "<CR>", { buffer = buf })
  end

  vim.fn.jobstart(M.login_argv(cmd), {
    term = true,
    cwd = path,
    on_exit = function(_, code)
      session.status = ("exited (%d)"):format(code)
      vim.schedule(function()
        local scrollback = {}
        if vim.api.nvim_buf_is_valid(buf) then
          scrollback = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          while #scrollback > 0 and vim.trim(scrollback[#scrollback]) == "" do
            table.remove(scrollback)
          end
        end
        record(session, scrollback, code)
        if code ~= 0 then
          vim.notify(("parole: agent %s exited with code %d"):format(session.title, code), vim.log.levels.WARN)
        end
        vim.cmd.checktime() -- pick up files the agent edited
        redraw_board()
      end)
    end,
  })
  vim.bo[buf].bufhidden = "hide" -- closing the tab must not kill the session
  -- land at the prompt whenever you come back to a live interactive session
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      if session.status == "running" and not session.headless then
        vim.cmd.startinsert()
      end
    end,
  })
  if not opts.headless then
    vim.cmd.startinsert()
  end
  redraw_board()
end

---Jump to the most recent running session; from inside a session, jump back
---to the previously accessed tab. Bind to something like <C-,> in n+t modes.
function M.toggle_last()
  local cur = vim.api.nvim_get_current_buf()
  local live = M.list()
  for _, s in ipairs(live) do
    if s.buf == cur then
      vim.cmd("silent! tabnext " .. vim.fn.tabpagenr("#"))
      return
    end
  end
  for i = #live, 1, -1 do
    if live[i].status == "running" then
      return M.focus(live[i])
    end
  end
  if #live > 0 then
    return M.focus(live[#live]) -- no running session: most recent finished one
  end
  vim.notify("parole: no agents on duty", vim.log.levels.WARN)
end

---@param header string description of where the agent is
---@param path string
---@param opts { headless: boolean, title: string }
local function with_context(header, path, opts)
  util.compose({
    title = "agent context — " .. opts.title,
    on_submit = function(context)
      launch(path, header .. "\n\n" .. context, opts)
    end,
  })
end

---Dispatch an agent onto a PR: worktree checkout + preloaded context.
---If a session for this PR is already running, jump to it instead.
---@param pr parole.Pr
---@param opts { headless: boolean }
function M.dispatch(pr, opts)
  local title = pr.slug .. "#" .. pr.number
  for _, s in ipairs(M.list()) do
    if s.title == title and s.status == "running" then
      vim.notify("parole: agent already on duty for " .. title .. " — jumping to it")
      return M.focus(s)
    end
  end
  require("parole.worktree").ensure(pr, function(path)
    if not path then
      return
    end
    local header = ('You are in a git worktree checked out to PR #%d of %s ("%s", %s -> %s).'):format(
      pr.number,
      pr.slug,
      pr.title,
      pr.head or "?",
      pr.base or "?"
    )
    with_context(header, path, { headless = opts.headless, title = pr.slug .. "#" .. pr.number })
  end)
end

---Dispatch an agent from the repo you're currently in, on a fresh branch.
---@param opts? { headless: boolean }
function M.dispatch_here(opts)
  opts = opts or { headless = false }
  local clone = vim.fs.root(0, ".git")
  if not clone then
    vim.notify("parole: not inside a git repo", vim.log.levels.ERROR)
    return
  end
  vim.ui.input({ prompt = "branch name for the agent worktree: ", default = "agent/" }, function(branch)
    if not branch or vim.trim(branch) == "" then
      return
    end
    require("parole.worktree").scratch(clone, branch, function(path)
      if not path then
        return
      end
      local header = ("You are in a fresh git worktree of %s on new branch %s."):format(vim.fs.basename(clone), branch)
      with_context(header, path, { headless = opts.headless, title = vim.fs.basename(clone) .. "@" .. branch })
    end)
  end)
end

return M
