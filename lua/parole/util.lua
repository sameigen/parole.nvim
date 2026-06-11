local M = {}

---Epoch seconds from UTC civil date fields (no localtime/DST involved).
---Days-from-civil per Howard Hinnant's algorithm.
---@return integer
local function utc_epoch(y, mo, d, h, mi, s)
  local yy = mo <= 2 and y - 1 or y
  local era = math.floor(yy / 400)
  local yoe = yy - era * 400
  local mp = (mo + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + h * 3600 + mi * 60 + s
end

---@param iso string? ISO-8601 UTC timestamp from the GitHub API
---@return string human relative age like "3d"
function M.age(iso)
  if not iso then
    return ""
  end
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return ""
  end
  local secs = os.time() - utc_epoch(tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s))
  if secs < 0 then
    secs = 0
  end
  if secs < 3600 then
    return math.floor(secs / 60) .. "m"
  elseif secs < 86400 then
    return math.floor(secs / 3600) .. "h"
  elseif secs < 86400 * 30 then
    return math.floor(secs / 86400) .. "d"
  end
  return math.floor(secs / (86400 * 30)) .. "mo"
end

---Summarise a statusCheckRollup list from `gh pr view`.
---@param rollup table[]?
---@return string icon, string hl
function M.checks_icon(rollup)
  if not rollup or #rollup == 0 then
    return "·", "Comment"
  end
  local pending, failed = false, false
  for _, c in ipairs(rollup) do
    local state = c.conclusion or c.state or ""
    if state == "FAILURE" or state == "ERROR" or state == "TIMED_OUT" or state == "CANCELLED" then
      failed = true
    elseif state == "" or state == "PENDING" or state == "IN_PROGRESS" or state == "QUEUED" or state == "EXPECTED" then
      pending = true
    end
  end
  if failed then
    return "✗", "DiagnosticError"
  elseif pending then
    return "◐", "DiagnosticWarn"
  end
  return "✓", "DiagnosticOk"
end

---@param decision string? reviewDecision from the API
---@return string label, string hl
function M.decision_label(decision)
  if decision == "APPROVED" then
    return "approved", "DiagnosticOk"
  elseif decision == "CHANGES_REQUESTED" then
    return "changes", "DiagnosticError"
  elseif decision == "REVIEW_REQUIRED" then
    return "review", "DiagnosticWarn"
  end
  return "", "Comment"
end

---Open a scratch compose split. The buffer submits on :w and aborts on :q.
---@param opts { title: string, on_submit: fun(body: string) }
function M.compose(opts)
  vim.cmd("botright 12split")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, "parole://" .. opts.title)
  vim.wo[0].winbar = "%#Title#" .. opts.title .. "%#Comment#  — :w submits, :q aborts"

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      vim.bo[buf].modified = false
      vim.api.nvim_win_close(0, true)
      if vim.trim(body) == "" then
        vim.notify("parole: empty body, aborted", vim.log.levels.WARN)
        return
      end
      opts.on_submit(body)
    end,
  })
  vim.cmd.startinsert()
end

---Pad or truncate a display string to an exact width.
---@param s string
---@param width integer
---@return string
function M.fit(s, width)
  s = s or ""
  local w = vim.fn.strdisplaywidth(s)
  if w > width then
    return vim.fn.strcharpart(s, 0, width - 1) .. "…"
  end
  return s .. string.rep(" ", width - w)
end

return M
