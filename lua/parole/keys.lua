---<Plug> dispatch and the `?` help popup.
---
---Every action is exposed as <Plug>(parole-<action>) (underscores become
---dashes), defined globally in plugin/parole.lua. The dispatcher routes an
---action to whichever parole buffer you're in.
local M = {}

---Action -> short description, used for <Plug> descs and the help popup.
M.descriptions = {
  open_case = "open case",
  approve = "approve (grant parole)",
  request_changes = "request changes",
  comment = "comment",
  reply = "reply to thread under cursor",
  diff = "view diff",
  deep_review = "deep review in worktree",
  octo = "open in octo",
  agent = "dispatch agent (interactive)",
  agent_headless = "dispatch agent (headless)",
  browse = "open in browser",
  expunge = "expunge agent record (output + optional worktree)",
  goto_file = "open file at this line (worktree)",
  hover = "read the full charge (untruncated title)",
  refresh = "refresh",
  close = "close",
  help = "show keymaps",
}

---@param action string
---@return string
function M.plug(action)
  return ("<Plug>(parole-%s)"):format(action:gsub("_", "-"))
end

---Run an action against the parole buffer under the cursor.
---@param action string
function M.run(action)
  if action == "help" then
    return M.help()
  end
  local board = require("parole.board")
  if board.is_board() then
    return board.do_action(action)
  end
  local case = require("parole.case")
  if case.is_case() then
    return case.do_action(action)
  end
  vim.notify(("parole: %s only works in parole buffers"):format(M.plug(action)), vim.log.levels.WARN)
end

---Show every parole keymap active in the current buffer in a float.
function M.help()
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
    if m.desc and m.desc:match("^parole: ") then
      table.insert(rows, { vim.fn.keytrans(m.lhsraw or m.lhs), m.desc:sub(#"parole: " + 1) })
    end
  end
  if #rows == 0 then
    vim.notify("parole: no parole keymaps in this buffer", vim.log.levels.WARN)
    return
  end
  table.sort(rows, function(a, b)
    return a[1]:lower() < b[1]:lower()
  end)

  local key_width = 0
  for _, row in ipairs(rows) do
    key_width = math.max(key_width, vim.fn.strdisplaywidth(row[1]))
  end
  local lines = {}
  for _, row in ipairs(rows) do
    table.insert(
      lines,
      ("  %s%s  %s"):format(row[1], string.rep(" ", key_width - vim.fn.strdisplaywidth(row[1])), row[2])
    )
  end
  local key_rows = #lines
  if require("parole.board").is_board() then
    table.insert(lines, "")
    table.insert(lines, "  checks column: ✓ passing · ✗ failing · ◐ running · ⋅ none or still loading")
  end

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width + 2,
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = " parole ",
    title_pos = "center",
  })
  local ns = vim.api.nvim_create_namespace("parole_help")
  for i = 1, key_rows do
    vim.hl.range(buf, ns, "Special", { i - 1, 0 }, { i - 1, 2 + key_width })
  end
  for i = key_rows + 1, #lines do
    vim.hl.range(buf, ns, "Comment", { i - 1, 0 }, { i - 1, #lines[i] })
  end
  for _, lhs in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", lhs, function()
      vim.api.nvim_win_close(win, true)
    end, { buffer = buf, silent = true, nowait = true })
  end
end

return M
