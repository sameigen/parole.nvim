local M = {}

function M.check()
  local health = vim.health
  health.start("parole.nvim")

  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim >= 0.11")
  else
    health.error("Neovim >= 0.11 required")
  end

  if vim.fn.executable("gh") == 1 then
    local res = vim.system({ "gh", "auth", "status" }, { text = true }):wait()
    if res.code == 0 then
      health.ok("gh CLI installed and authenticated")
    else
      health.error("gh CLI installed but not authenticated — run `gh auth login`")
    end
  else
    health.error("gh CLI not found — https://cli.github.com")
  end

  if vim.fn.executable("git") == 1 then
    health.ok("git installed")
  else
    health.error("git not found")
  end

  local agent = require("parole").config.agent
  local prof = agent.profiles[agent.use]
  if prof and vim.fn.executable(prof.cmd[1]) == 1 then
    health.ok(("agent profile %q: `%s` found"):format(agent.use, prof.cmd[1]))
  else
    health.warn(("agent profile %q: command not found — dispatch won't work"):format(agent.use))
  end
  if agent.yolo then
    health.warn("agent.yolo is ON — agents run with ALL permission checks disabled")
  end
  if agent.auto then
    health.info("agent.auto is on — agents auto-accept edits")
  end

  for _, opt in ipairs({
    { mod = "fzf-lua", why = ":ParolePick" },
    { mod = "octo", why = "octo handoff (o)" },
    { mod = "diffview", why = "deep review diffs (falls back to fugitive)" },
  }) do
    if pcall(require, opt.mod) then
      health.ok(("optional: %s available (%s)"):format(opt.mod, opt.why))
    else
      health.info(("optional: %s not installed (%s)"):format(opt.mod, opt.why))
    end
  end
end

return M
