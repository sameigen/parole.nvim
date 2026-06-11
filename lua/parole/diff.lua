---Quick diff: the PR's full patch in a scratch buffer — no worktree, no API
---review session. The drive-by middle ground between the board and `D`.
---Supports inline comments: the cursor line is mapped back to a (path, line,
---side) position and posted as a review comment.
local gh = require("parole.gh")
local util = require("parole.util")

local M = {}

---@type table<integer, { pr: parole.Pr, sha: string? }> keyed by bufnr
local diffs = {}

---Map a buffer line in a unified diff back to a commentable position.
---@param buf integer
---@param lnum integer 1-based cursor line
---@return { path: string, line: integer, side: "LEFT"|"RIGHT" }?
function M.locate(buf, lnum)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, lnum, false)
  local hunk_idx
  for i = lnum, 1, -1 do
    local l = lines[i]
    if l:match("^@@") then
      hunk_idx = i
      break
    end
    if l:match("^diff %-%-git ") then
      return nil -- cursor sits in a file header, not a hunk
    end
  end
  if not hunk_idx or lnum <= hunk_idx then
    return nil
  end
  local path
  for i = hunk_idx, 1, -1 do
    local p = lines[i]:match("^%+%+%+ b/(.+)$")
    if p then
      path = p
      break
    end
  end
  if not path then
    return nil
  end
  local old_start, new_start = lines[hunk_idx]:match("^@@ %-(%d+)[%d,]* %+(%d+)")
  if not new_start then
    return nil
  end
  local old_l, new_l = tonumber(old_start) - 1, tonumber(new_start) - 1
  local side, line
  for i = hunk_idx + 1, lnum do
    local marker = lines[i]:sub(1, 1)
    if marker == "+" then
      new_l = new_l + 1
      side, line = "RIGHT", new_l
    elseif marker == "-" then
      old_l = old_l + 1
      side, line = "LEFT", old_l
    else
      new_l, old_l = new_l + 1, old_l + 1
      side, line = "RIGHT", new_l
    end
  end
  return { path = path, line = line, side = side }
end

---@param buf integer
local function comment_at_cursor(buf)
  local state = diffs[buf]
  if not state then
    return
  end
  local pos = M.locate(buf, vim.api.nvim_win_get_cursor(0)[1])
  if not pos then
    return vim.notify("parole: put the cursor on a diff line inside a hunk", vim.log.levels.WARN)
  end
  if not state.sha then
    return vim.notify("parole: head commit not resolved yet, try again in a second", vim.log.levels.WARN)
  end
  local pr = state.pr
  util.compose({
    title = ("comment on %s:%d"):format(pos.path, pos.line),
    on_submit = function(body)
      gh.run({
        "api",
        ("repos/%s/pulls/%d/comments"):format(pr.slug, pr.number),
        "-f",
        "body=" .. body,
        "-f",
        "commit_id=" .. state.sha,
        "-f",
        "path=" .. pos.path,
        "-F",
        "line=" .. pos.line,
        "-f",
        "side=" .. pos.side,
      }, function(err)
        if err then
          return vim.notify("parole: " .. err, vim.log.levels.ERROR)
        end
        vim.notify(("parole: comment posted on %s:%d"):format(pos.path, pos.line))
      end)
    end,
  })
end

---@param buf integer
local function goto_file(buf)
  local state = diffs[buf]
  if not state then
    return
  end
  local pos = M.locate(buf, vim.api.nvim_win_get_cursor(0)[1])
  if not pos then
    return vim.notify("parole: put the cursor on a diff line inside a hunk", vim.log.levels.WARN)
  end
  require("parole.worktree").ensure(state.pr, function(path)
    if not path then
      return
    end
    vim.cmd.tabedit(vim.fn.fnameescape(path .. "/" .. pos.path))
    pcall(vim.api.nvim_win_set_cursor, 0, { pos.line, 0 })
    vim.cmd.normal({ "zz", bang = true })
  end)
end

---@param buf integer
local function setup_keymaps(buf)
  local keys = require("parole.keys")
  local k = require("parole").config.keymaps.diff
  local handlers = {
    comment = function()
      comment_at_cursor(buf)
    end,
    goto_file = function()
      goto_file(buf)
    end,
    close = "<cmd>tabclose<CR>",
    help = keys.help,
  }
  for action, lhs in pairs(k) do
    if lhs and handlers[action] then
      vim.keymap.set("n", lhs, handlers[action], {
        buffer = buf,
        silent = true,
        nowait = true,
        desc = "parole: " .. (keys.descriptions[action] or action),
      })
    end
  end
end

---@param pr parole.Pr
function M.open(pr)
  local name = ("parole://diff/%s/%d"):format(pr.slug, pr.number)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and diffs[existing] then
    vim.cmd.tabnew()
    vim.api.nvim_win_set_buf(0, existing)
    return
  end
  vim.notify(("parole: fetching diff for %s#%d…"):format(pr.slug, pr.number))
  gh.run({ "pr", "diff", tostring(pr.number), "--repo", pr.slug }, function(err, out)
    if err then
      return vim.notify("parole: " .. err, vim.log.levels.ERROR)
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(out or "", "\n"))
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "diff"
    diffs[buf] = { pr = pr }
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      callback = function()
        diffs[buf] = nil
      end,
    })
    vim.cmd.tabnew()
    vim.api.nvim_win_set_buf(0, buf)
    vim.wo[0].foldmethod = "expr"
    vim.wo[0].foldexpr = "v:lua.require'parole.diff'.foldexpr(v:lnum)"
    vim.wo[0].foldlevel = 1
    setup_keymaps(buf)
    -- resolve the head SHA in the background; needed to anchor comments
    gh.json({ "pr", "view", tostring(pr.number), "--repo", pr.slug, "--json", "headRefOid" }, function(view_err, data)
      if not view_err and data and diffs[buf] then
        diffs[buf].sha = data.headRefOid
      end
    end)
  end)
end

---Fold per file: `diff --git` headers open a new fold.
---@param lnum integer
---@return string
function M.foldexpr(lnum)
  local line = vim.fn.getline(lnum)
  if line:match("^diff %-%-git ") then
    return ">1"
  end
  return "1"
end

return M
