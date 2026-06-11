---fzf-lua picker over every PR currently on (or fetchable for) the board.
local M = {}

---@param prs parole.Pr[]
local function open_picker(prs)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("parole: fzf-lua is not installed", vim.log.levels.WARN)
    return
  end
  local by_display = {}
  local entries = {}
  for _, pr in ipairs(prs) do
    local display = ("%s#%d  %s  (@%s)"):format(pr.slug, pr.number, pr.title, pr.author)
    by_display[display] = pr
    table.insert(entries, display)
  end

  local function selected_pr(sel)
    return sel and sel[1] and by_display[sel[1]]
  end

  fzf.fzf_exec(entries, {
    prompt = "parole> ",
    actions = {
      ["enter"] = function(sel)
        local pr = selected_pr(sel)
        if pr then
          require("parole.case").open(pr.owner, pr.repo, pr.number)
        end
      end,
      ["ctrl-d"] = function(sel)
        local pr = selected_pr(sel)
        if pr then
          require("parole.worktree").review(pr)
        end
      end,
      ["ctrl-a"] = function(sel)
        local pr = selected_pr(sel)
        if pr then
          require("parole.agent").dispatch(pr, { headless = false })
        end
      end,
      ["ctrl-o"] = function(sel)
        local pr = selected_pr(sel)
        if pr then
          require("parole.actions").octo(pr)
        end
      end,
      ["ctrl-b"] = function(sel)
        local pr = selected_pr(sel)
        if pr then
          vim.ui.open(pr.url)
        end
      end,
    },
  })
end

function M.open()
  local board = require("parole.board")
  local prs = board.all_prs()
  if #prs > 0 then
    return open_picker(prs)
  end
  -- nothing cached: do one involves-search inline
  local config = require("parole").config
  local args = {
    "search",
    "prs",
    "--state=open",
    "--involves=@me",
    "--limit",
    tostring(config.limit),
    "--json",
    "number,title,repository,author,updatedAt,url,isDraft",
  }
  for _, owner in ipairs(config.owners) do
    table.insert(args, "--owner=" .. owner)
  end
  require("parole.gh").json(args, function(err, data)
    if err then
      return vim.notify("parole: " .. err, vim.log.levels.ERROR)
    end
    local prs_fresh = {}
    for _, raw in ipairs(data or {}) do
      local slug = raw.repository and raw.repository.nameWithOwner or ""
      local owner, repo = slug:match("([^/]+)/(.+)")
      table.insert(prs_fresh, {
        slug = slug,
        owner = owner,
        repo = repo,
        number = raw.number,
        title = raw.title or "",
        author = raw.author and raw.author.login or "",
        url = raw.url,
        is_draft = raw.isDraft or false,
      })
    end
    open_picker(prs_fresh)
  end)
end

return M
