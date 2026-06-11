---The case file: a single PR rendered as a readable markdown buffer,
---with review threads, checks, and verdict actions.
local gh = require("parole.gh")
local util = require("parole.util")

local M = {}

---@class parole.Case
---@field owner string
---@field repo string
---@field number integer
---@field slug string
---@field data table?
---@field threads table[]?
---@field thread_at table<integer, table> buffer line -> review thread

---@type table<integer, parole.Case> keyed by bufnr
local cases = {}

local THREADS_QUERY = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          id isResolved isOutdated path line
          comments(first: 50) { nodes { author { login } body createdAt diffHunk } }
        }
      }
    }
  }
}]]

local VIEW_FIELDS = table.concat({
  "number",
  "title",
  "body",
  "author",
  "baseRefName",
  "headRefName",
  "state",
  "isDraft",
  "reviewDecision",
  "statusCheckRollup",
  "additions",
  "deletions",
  "changedFiles",
  "labels",
  "commits",
  "reviews",
  "comments",
  "url",
  "createdAt",
  "mergeable",
}, ",")

---@param case parole.Case
---@return parole.Pr minimal PR shape shared with the board
local function as_pr(case)
  local d = case.data or {}
  return {
    slug = case.slug,
    owner = case.owner,
    repo = case.repo,
    number = case.number,
    title = d.title or "",
    author = d.author and d.author.login or "",
    url = d.url or ("https://github.com/" .. case.slug .. "/pull/" .. case.number),
    is_draft = d.isDraft or false,
    head = d.headRefName,
    base = d.baseRefName,
  }
end

---@param case parole.Case
---@param buf integer
local function render(case, buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local d = case.data
  local lines = {}
  case.thread_at = {}
  local function add(s)
    for _, l in ipairs(vim.split(s or "", "\n")) do
      table.insert(lines, l)
    end
  end

  if not d then
    add("# " .. case.slug .. " #" .. case.number)
    add("")
    add("_loading…_")
  else
    add("# " .. d.title .. " (#" .. d.number .. ")")
    add("")
    local meta = string.format(
      "`%s` · `%s → %s` · @%s · opened %s ago · **+%d −%d** across %d files",
      case.slug,
      d.headRefName or "?",
      d.baseRefName or "?",
      d.author and d.author.login or "?",
      util.age(d.createdAt),
      d.additions or 0,
      d.deletions or 0,
      d.changedFiles or 0
    )
    add(meta)
    add("")
    local decision = util.decision_label(d.reviewDecision)
    local checks_icon = util.checks_icon(d.statusCheckRollup)
    if not d.statusCheckRollup or #d.statusCheckRollup == 0 then
      checks_icon = "none"
    end
    local labels = {}
    for _, l in ipairs(d.labels or {}) do
      table.insert(labels, "`" .. l.name .. "`")
    end
    add(
      ("**State:** %s%s · **Review:** %s · **Checks:** %s · **Mergeable:** %s%s"):format(
        d.state or "?",
        d.isDraft and " (draft)" or "",
        decision ~= "" and decision or "—",
        checks_icon,
        string.lower(d.mergeable or "?"),
        #labels > 0 and (" · " .. table.concat(labels, " ")) or ""
      )
    )

    -- failing / pending checks get listed; all-green stays one icon
    local noisy = {}
    for _, c in ipairs(d.statusCheckRollup or {}) do
      local conclusion = c.conclusion or c.state or ""
      if conclusion ~= "SUCCESS" and conclusion ~= "NEUTRAL" and conclusion ~= "SKIPPED" then
        table.insert(
          noisy,
          ("- %s `%s` %s"):format(
            conclusion == "FAILURE" and "✗" or "◐",
            c.name or c.context,
            string.lower(conclusion)
          )
        )
      end
    end
    if #noisy > 0 then
      add("")
      add("## Checks")
      add(table.concat(noisy, "\n"))
    end

    if d.body and vim.trim(d.body) ~= "" then
      add("")
      add("---")
      add("")
      add(d.body:gsub("\r", ""))
    end

    if d.commits and #d.commits > 0 then
      add("")
      add("## Commits (" .. #d.commits .. ")")
      for _, c in ipairs(d.commits) do
        local author = c.authors and c.authors[1] or {}
        local who = (author.login and author.login ~= "") and author.login or (author.name or "?")
        add(
          ("- `%s` %s — @%s, %s ago"):format(
            (c.oid or ""):sub(1, 7),
            c.messageHeadline or "",
            who,
            util.age(c.committedDate)
          )
        )
      end
    end

    if d.reviews and #d.reviews > 0 then
      add("")
      add("## Reviews")
      for _, r in ipairs(d.reviews) do
        local who = r.author and r.author.login or "?"
        add(("- **@%s** %s (%s ago)"):format(who, string.lower(r.state or ""), util.age(r.submittedAt)))
        if r.body and vim.trim(r.body) ~= "" then
          add("  > " .. r.body:gsub("\r", ""):gsub("\n", "\n  > "))
        end
      end
    end

    if case.threads and #case.threads > 0 then
      add("")
      add("## Threads")
      for _, t in ipairs(case.threads) do
        add("")
        local status = t.isResolved and "resolved" or "open"
        if t.isOutdated then
          status = status .. ", outdated"
        end
        local header = ("### `%s%s` _(%s)_"):format(t.path or "?", t.line and (":" .. t.line) or "", status)
        add(header)
        local start_line = #lines
        -- the commented diff hunk; GitHub anchors the comment to its last line
        local first = t.comments and t.comments.nodes and t.comments.nodes[1]
        if first and first.diffHunk and first.diffHunk ~= "" then
          local hunk = vim.split(first.diffHunk:gsub("\r", ""), "\n")
          if #hunk > 12 then
            hunk = vim.list_slice(hunk, #hunk - 11, #hunk)
            table.insert(hunk, 1, "···")
          end
          add("```diff")
          for _, hl_line in ipairs(hunk) do
            add(hl_line)
          end
          add("```")
        end
        for _, c in ipairs((t.comments and t.comments.nodes) or {}) do
          local who = c.author and c.author.login or "?"
          add(("**@%s** (%s ago):"):format(who, util.age(c.createdAt)))
          add("> " .. (c.body or ""):gsub("\r", ""):gsub("\n", "\n> "))
        end
        for l = start_line, #lines do
          case.thread_at[l] = t
        end
      end
    end

    if d.comments and #d.comments > 0 then
      add("")
      add("## Comments")
      for _, c in ipairs(d.comments) do
        add("")
        add(("**@%s** (%s ago):"):format(c.author and c.author.login or "?", util.age(c.createdAt)))
        add("> " .. (c.body or ""):gsub("\r", ""):gsub("\n", "\n> "))
      end
    end

    add("")
    add("---")
    local k = require("parole").config.keymaps.case
    add(
      ("_%s approve · %s request changes · %s comment · %s reply · %s diff · %s all keys_"):format(
        k.approve or "-",
        k.request_changes or "-",
        k.comment or "-",
        k.reply or "-",
        k.diff or "-",
        k.help or "-"
      )
    )
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

---@param case parole.Case
---@param buf integer
local function fetch(case, buf)
  case.gen = (case.gen or 0) + 1
  local gen = case.gen
  gh.json({ "pr", "view", tostring(case.number), "--repo", case.slug, "--json", VIEW_FIELDS }, function(err, data)
    if gen ~= case.gen then
      return -- superseded by a newer fetch
    end
    if err then
      vim.notify("parole: " .. err, vim.log.levels.ERROR)
      return
    end
    case.data = data
    render(case, buf)
  end)
  gh.graphql(THREADS_QUERY, { owner = case.owner, name = case.repo, number = case.number }, function(err, data)
    if gen ~= case.gen or err then
      return
    end
    local ok, nodes = pcall(function()
      return data.data.repository.pullRequest.reviewThreads.nodes
    end)
    if ok and nodes then
      case.threads = nodes
      render(case, buf)
    end
  end)
end

---@param buf? integer defaults to the current buffer
---@return boolean
function M.is_case(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  return cases[buf] ~= nil
end

---Run a named action against the case in the current buffer.
---@param action string
function M.do_action(action)
  local buf = vim.api.nvim_get_current_buf()
  local case = cases[buf]
  if not case then
    return vim.notify("parole: not in a case buffer", vim.log.levels.WARN)
  end
  local actions = require("parole.actions")
  local function refresh()
    fetch(case, buf)
  end
  local dispatch = {
    approve = function()
      actions.approve(as_pr(case), refresh)
    end,
    request_changes = function()
      actions.request_changes(as_pr(case), refresh)
    end,
    comment = function()
      actions.comment(as_pr(case), refresh)
    end,
    reply = function()
      local t = case.thread_at[vim.api.nvim_win_get_cursor(0)[1]]
      if not t then
        return vim.notify("parole: cursor is not on a review thread", vim.log.levels.WARN)
      end
      actions.reply(t.id, refresh)
    end,
    diff = function()
      require("parole.diff").open(as_pr(case))
    end,
    deep_review = function()
      require("parole.worktree").review(as_pr(case))
    end,
    octo = function()
      actions.octo(as_pr(case))
    end,
    browse = function()
      vim.ui.open(as_pr(case).url)
    end,
    goto_file = function()
      local t = case.thread_at[vim.api.nvim_win_get_cursor(0)[1]]
      if not t or not t.path then
        return vim.notify("parole: cursor is not on a review thread", vim.log.levels.WARN)
      end
      require("parole.worktree").ensure(as_pr(case), function(path)
        if not path then
          return
        end
        vim.cmd.tabedit(vim.fn.fnameescape(path .. "/" .. t.path))
        if t.line then
          pcall(vim.api.nvim_win_set_cursor, 0, { t.line, 0 })
          vim.cmd.normal({ "zz", bang = true })
        end
      end)
    end,
    refresh = refresh,
    close = function()
      vim.cmd.close({ mods = { silent = true } })
    end,
  }
  local fn = dispatch[action]
  if not fn then
    return vim.notify(("parole: action %q is not available in a case buffer"):format(action), vim.log.levels.WARN)
  end
  fn()
end

---@param buf integer
local function setup_keymaps(buf)
  local keys = require("parole.keys")
  for action, lhs in pairs(require("parole").config.keymaps.case) do
    if lhs then
      vim.keymap.set("n", lhs, keys.plug(action), {
        buffer = buf,
        remap = true,
        silent = true,
        nowait = true,
        desc = "parole: " .. (keys.descriptions[action] or action),
      })
    end
  end
end

---@param owner string
---@param repo string
---@param number integer
function M.open(owner, repo, number)
  local name = ("parole://%s/%s/%d"):format(owner, repo, number)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and cases[existing] then
    vim.api.nvim_win_set_buf(0, existing)
    fetch(cases[existing], existing)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"

  local case = {
    owner = owner,
    repo = repo,
    number = number,
    slug = owner .. "/" .. repo,
    thread_at = {},
  }
  cases[buf] = case

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      cases[buf] = nil
    end,
  })

  vim.api.nvim_win_set_buf(0, buf)
  vim.wo[0].wrap = true
  vim.wo[0].linebreak = true
  vim.wo[0].conceallevel = 2

  setup_keymaps(buf)
  render(case, buf)
  fetch(case, buf)
end

return M
