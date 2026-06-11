---The Board: a cross-repo dashboard of open PRs that involve you.
local gh = require("parole.gh")
local util = require("parole.util")

local M = {}

local ns = vim.api.nvim_create_namespace("parole_board")

---@class parole.Pr
---@field slug string "owner/repo"
---@field owner string
---@field repo string
---@field number integer
---@field title string
---@field author string
---@field updated string?
---@field url string
---@field is_draft boolean
---@field decision string?
---@field checks table[]?
---@field head string?
---@field base string?
---@field enriched boolean?

local state = {
  buf = nil, ---@type integer?
  timer = nil, ---@type uv.uv_timer_t?
  loading = false,
  generation = 0, -- bumped on every refresh; stale async results are dropped
  fetched_at = nil, ---@type integer?
  sections = {}, ---@type { title: string, prs: parole.Pr[] }[]
  line_map = {}, ---@type table<integer, parole.Pr>
}

local SECTIONS = {
  { key = "review-requested", title = "AWAITING YOUR VERDICT", flag = "--review-requested=@me" },
  { key = "mine", title = "YOUR CASES", flag = "--author=@me" },
  { key = "involved", title = "INVOLVED", flag = "--involves=@me" },
}

---@param raw table item from `gh search prs --json`
---@return parole.Pr
local function normalize(raw)
  local slug = raw.repository and raw.repository.nameWithOwner or ""
  local owner, repo = slug:match("([^/]+)/(.+)")
  return {
    slug = slug,
    owner = owner or "",
    repo = repo or slug,
    number = raw.number,
    title = raw.title or "",
    author = raw.author and raw.author.login or "",
    updated = raw.updatedAt,
    url = raw.url,
    is_draft = raw.isDraft or false,
  }
end

local function search_args(flag)
  local config = require("parole").config
  local args = {
    "search",
    "prs",
    "--state=open",
    flag,
    "--limit",
    tostring(config.limit),
    "--json",
    "number,title,repository,author,updatedAt,url,isDraft",
  }
  for _, owner in ipairs(config.owners) do
    table.insert(args, "--owner=" .. owner)
  end
  return args
end

local function buf_valid()
  return state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

local function render()
  if not buf_valid() then
    return
  end
  local lines, marks = {}, {}
  state.line_map = {}

  local function add(line, hl_spans)
    table.insert(lines, line)
    for _, span in ipairs(hl_spans or {}) do
      table.insert(marks, { #lines - 1, span[1], span[2], span[3] })
    end
  end

  local stamp = state.loading and "refreshing…"
    or (state.fetched_at and ("as of " .. os.date("%H:%M:%S", state.fetched_at)) or "")

  -- fixed narrow columns on the left; the title runs last at natural width,
  -- so nothing needs to scale with the window
  for _, section in ipairs(state.sections) do
    add("", {})
    add(section.title .. "  (" .. #section.prs .. ")", { { 0, -1, "Title" } })
    if #section.prs == 0 then
      add("  none", { { 0, -1, "Comment" } })
    end
    for _, pr in ipairs(section.prs) do
      local icon, icon_hl = util.checks_icon(pr.checks)
      if not pr.enriched then
        icon, icon_hl = "·", "Comment"
      end
      local decision, decision_hl = util.decision_label(pr.decision)
      local parts = {
        { icon, icon_hl },
        { util.fit(pr.repo, 20), "Directory" },
        { util.fit("#" .. pr.number, 6), "Number" },
        { util.fit("@" .. pr.author, 12), "Comment" },
        { util.fit(decision, 8), decision_hl },
        { util.fit(util.age(pr.updated), 4), "Comment" },
        { pr.title, pr.is_draft and "Comment" or "Normal" },
      }
      local line, spans, col = "  ", {}, 2
      for _, part in ipairs(parts) do
        line = line .. part[1] .. " "
        table.insert(spans, { col, col + #part[1], part[2] })
        col = col + #part[1] + 1
      end
      add(line, spans)
      state.line_map[#lines] = pr
    end
  end

  local function agent_row(icon, icon_hl, title, mode, status, status_hl, age)
    local parts = {
      { icon, icon_hl },
      { util.fit(title, 40), "Normal" },
      { util.fit(mode, 11), "Comment" },
      { util.fit(status, 12), status_hl },
      { age, "Comment" },
    }
    local line, spans, col = "  ", {}, 2
    for _, part in ipairs(parts) do
      line = line .. part[1] .. " "
      table.insert(spans, { col, col + #part[1], part[2] })
      col = col + #part[1] + 1
    end
    add(line, spans)
  end

  state.agent_at = {}
  state.history_at = {}
  local agents = require("parole.agent").list()
  if #agents > 0 then
    add("", {})
    add("AGENTS ON DUTY  (" .. #agents .. ")", { { 0, -1, "Title" } })
    for _, s in ipairs(agents) do
      local running = s.status == "running"
      agent_row(
        running and "●" or "✗",
        running and "DiagnosticOk" or "DiagnosticError",
        s.title,
        s.headless and "headless" or "interactive",
        s.status,
        running and "Comment" or "DiagnosticError",
        util.age(os.date("!%Y-%m-%dT%H:%M:%SZ", s.started) --[[@as string]])
      )
      state.agent_at[#lines] = s
    end
  end

  local history = require("parole.agent").history()
  if #history > 0 then
    add("", {})
    add("CASE HISTORY  (" .. #history .. ")", { { 0, -1, "Title" } })
    for i, h in ipairs(history) do
      if i > 8 then
        add(
          "  … " .. (#history - 8) .. " more in " .. vim.fn.stdpath("state") .. "/parole/agents",
          { { 0, -1, "Comment" } }
        )
        break
      end
      local ok = h.exit == 0
      agent_row(
        ok and "✓" or "✗",
        ok and "DiagnosticOk" or "DiagnosticError",
        h.title,
        h.mode,
        ok and "done" or ("exited (" .. (h.exit or "?") .. ")"),
        ok and "Comment" or "DiagnosticError",
        util.age(os.date("!%Y-%m-%dT%H:%M:%SZ", h.mtime) --[[@as string]])
      )
      state.history_at[#lines] = h
    end
  end

  add("", {})
  local k = require("parole").config.keymaps.board
  add(
    (" %s case · %s diff · %s deep review · %s agent · %s full title · %s all keys"):format(
      k.open_case or "-",
      k.diff or "-",
      k.deep_review or "-",
      k.agent or "-",
      k.hover or "-",
      k.help or "-"
    ),
    { { 0, -1, "Comment" } }
  )

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    pcall(vim.hl.range, state.buf, ns, m[4], { m[1], m[2] }, { m[1], m[3] == -1 and 2147483646 or m[3] })
  end

  -- column headers pinned in the winbar; board title + stamp right-aligned
  local header = ("%%#Comment#  ✓ %s %s %s %s %s title%%=%%#Title#PAROLE BOARD%%#Comment# %s "):format(
    util.fit("repo", 20),
    util.fit("#", 6),
    util.fit("author", 12),
    util.fit("review", 8),
    util.fit("age", 4),
    stamp
  )
  for _, w in ipairs(vim.fn.win_findbuf(state.buf)) do
    vim.api.nvim_set_option_value("winbar", header, { win = w })
  end
end

---Fetch checks/review-decision for each PR with bounded concurrency.
local function enrich()
  local gen = state.generation
  local jobs = {}
  for _, section in ipairs(state.sections) do
    for _, pr in ipairs(section.prs) do
      if not pr.enriched then
        table.insert(jobs, function(done)
          gh.json({
            "pr",
            "view",
            tostring(pr.number),
            "--repo",
            pr.slug,
            "--json",
            "reviewDecision,statusCheckRollup,headRefName,baseRefName",
          }, function(err, data)
            if gen ~= state.generation then
              return done() -- a newer refresh owns the board now
            end
            if not err and data then
              pr.decision = data.reviewDecision
              pr.checks = data.statusCheckRollup
              pr.head = data.headRefName
              pr.base = data.baseRefName
              pr.enriched = true
              render()
            end
            done()
          end)
        end)
      end
    end
  end
  gh.pool(jobs, 8)
end

function M.refresh()
  if state.loading then
    return
  end
  state.loading = true
  state.generation = state.generation + 1
  render()

  local results, pending = {}, #SECTIONS
  for _, section in ipairs(SECTIONS) do
    gh.json(search_args(section.flag), function(err, data)
      results[section.key] = (not err and data) or {}
      if err then
        vim.notify("parole: " .. tostring(err), vim.log.levels.WARN)
      end
      pending = pending - 1
      if pending > 0 then
        return
      end
      -- all three searches done: dedup later sections against earlier ones
      local seen = {}
      state.sections = {}
      for _, s in ipairs(SECTIONS) do
        local prs = {}
        for _, raw in ipairs(results[s.key]) do
          local pr = normalize(raw)
          local key = pr.slug .. "#" .. pr.number
          if not seen[key] then
            seen[key] = true
            table.insert(prs, pr)
          end
        end
        table.insert(state.sections, { title = s.title, prs = prs })
      end
      state.loading = false
      state.fetched_at = os.time()
      render()
      enrich()
    end)
  end
end

---@return parole.Pr?
local function pr_at_cursor()
  local pr = state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
  if not pr then
    vim.notify("parole: no PR on this line", vim.log.levels.WARN)
  end
  return pr
end

---Float with the untruncated title and core metadata ("the full charge").
---@param pr parole.Pr
local function hover(pr)
  local lines = { pr.title, "", ("%s#%d · @%s · %s ago"):format(pr.slug, pr.number, pr.author, util.age(pr.updated)) }
  if pr.head and pr.base then
    lines[3] = lines[3] .. (" · %s → %s"):format(pr.head, pr.base)
  end
  local width = math.min(80, vim.o.columns - 4)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local height = math.max(3, math.ceil(vim.fn.strdisplaywidth(pr.title) / width) + 2)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " the full charge ",
    title_pos = "center",
    focusable = false,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
    buffer = state.buf,
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })
end

---@type table<string, fun(pr: parole.Pr)> actions that need the PR under the cursor
local pr_actions = {}

---@param buf? integer defaults to the current buffer
---@return boolean
function M.is_board(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  return buf_valid() and buf == state.buf
end

---Re-render with current data (no fetch). Safe to call from anywhere.
function M.redraw()
  render()
end

---Run a named action against the board (used by <Plug>(parole-*) dispatch).
---@param action string
function M.do_action(action)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local agent = require("parole.agent")
  local session = state.agent_at[lnum]
  local entry = state.history_at and state.history_at[lnum]
  if session then
    if action == "open_case" then
      return agent.focus(session)
    elseif action == "expunge" then
      if session.status == "running" then
        return vim.notify("parole: still on duty — won't expunge a running agent", vim.log.levels.WARN)
      end
      return agent.expunge({ title = session.title, file = session.record, worktree = session.path }, function()
        if vim.api.nvim_buf_is_valid(session.buf) then
          vim.api.nvim_buf_delete(session.buf, { force = true })
        end
        render()
      end)
    end
  end
  if entry then
    if action == "open_case" then
      return vim.cmd.edit(vim.fn.fnameescape(entry.file))
    elseif action == "expunge" then
      return agent.expunge(entry, render)
    end
  end
  if action == "refresh" then
    return M.refresh()
  end
  if action == "close" then
    return vim.cmd.close({ mods = { silent = true } })
  end
  local fn = pr_actions[action]
  if not fn then
    return vim.notify(("parole: action %q is not available on the board"):format(action), vim.log.levels.WARN)
  end
  local pr = pr_at_cursor()
  if pr then
    fn(pr)
  end
end

local function setup_keymaps()
  local keys = require("parole.keys")
  for action, lhs in pairs(require("parole").config.keymaps.board) do
    if lhs then
      vim.keymap.set("n", lhs, keys.plug(action), {
        buffer = state.buf,
        remap = true,
        silent = true,
        nowait = true,
        desc = "parole: " .. (keys.descriptions[action] or action),
      })
    end
  end
end

pr_actions.hover = hover
pr_actions.open_case = function(pr)
  require("parole.case").open(pr.owner, pr.repo, pr.number)
end
pr_actions.octo = function(pr)
  require("parole.actions").octo(pr)
end
pr_actions.diff = function(pr)
  require("parole.diff").open(pr)
end
pr_actions.deep_review = function(pr)
  require("parole.worktree").review(pr)
end
pr_actions.agent = function(pr)
  require("parole.agent").dispatch(pr, { headless = false })
end
pr_actions.agent_headless = function(pr)
  require("parole.agent").dispatch(pr, { headless = true })
end
pr_actions.browse = function(pr)
  vim.ui.open(pr.url)
end

local function start_timer()
  local interval = require("parole").config.refresh_interval
  if interval <= 0 or state.timer then
    return
  end
  state.timer = vim.uv.new_timer()
  state.timer:start(
    interval * 1000,
    interval * 1000,
    vim.schedule_wrap(function()
      if buf_valid() and #vim.fn.win_findbuf(state.buf) > 0 then
        M.refresh()
      end
    end)
  )
end

local WINDOW_OPTS = { wrap = false, cursorline = true, number = false, relativenumber = false, signcolumn = "no" }

---Apply board window options, remembering the previous values for restore.
local function attach_window()
  local prior = { winbar = vim.wo[0].winbar }
  for opt, value in pairs(WINDOW_OPTS) do
    prior[opt] = vim.wo[0][opt]
    vim.wo[0][opt] = value
  end
  state.prior_opts = prior
end

function M.open()
  if buf_valid() then
    local wins = vim.fn.win_findbuf(state.buf)
    if #wins > 0 then
      vim.api.nvim_set_current_win(wins[1])
    else
      vim.api.nvim_win_set_buf(0, state.buf)
      attach_window()
    end
    M.refresh()
    return
  end

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.buf, "parole://board")
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "parole-board"
  vim.api.nvim_win_set_buf(0, state.buf)
  attach_window()

  local group = vim.api.nvim_create_augroup("parole_board", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = state.buf,
    callback = function()
      if state.timer then
        state.timer:stop()
        state.timer:close()
        state.timer = nil
      end
      state.buf = nil
    end,
  })
  -- restore the window's own options when the board leaves it
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = state.buf,
    callback = function()
      for opt, value in pairs(state.prior_opts or {}) do
        pcall(vim.api.nvim_set_option_value, opt, value, { win = vim.api.nvim_get_current_win() })
      end
    end,
  })
  setup_keymaps()
  start_timer()
  M.refresh()
  require("parole.worktree").sweep()
end

---@return parole.Pr[] flat list of everything currently on the board
function M.all_prs()
  local out = {}
  for _, section in ipairs(state.sections) do
    vim.list_extend(out, section.prs)
  end
  return out
end

return M
