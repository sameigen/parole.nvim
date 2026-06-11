---Verdicts and other write actions, all via `gh`.
local gh = require("parole.gh")
local util = require("parole.util")

local M = {}

---@param pr parole.Pr
---@param kind "--approve"|"--request-changes"
---@param label string
---@param after? fun()
local function review(pr, kind, label, after)
  vim.ui.input({ prompt = label .. " " .. pr.slug .. "#" .. pr.number .. " — comment (optional): " }, function(body)
    if body == nil then
      return -- aborted
    end
    local args = { "pr", "review", tostring(pr.number), "--repo", pr.slug, kind }
    if vim.trim(body) ~= "" then
      vim.list_extend(args, { "--body", body })
    end
    gh.run(args, function(err)
      if err then
        return vim.notify("parole: " .. err, vim.log.levels.ERROR)
      end
      vim.notify(("parole: %s %s#%d"):format(label:lower(), pr.slug, pr.number))
      if after then
        after()
      end
    end)
  end)
end

---@param pr parole.Pr
---@param after? fun()
function M.approve(pr, after)
  review(pr, "--approve", "Parole granted:", after)
end

---@param pr parole.Pr
---@param after? fun()
function M.request_changes(pr, after)
  review(pr, "--request-changes", "Parole denied:", after)
end

---@param pr parole.Pr
---@param after? fun()
function M.comment(pr, after)
  util.compose({
    title = "comment on " .. pr.slug .. "#" .. pr.number,
    on_submit = function(body)
      gh.run({ "pr", "comment", tostring(pr.number), "--repo", pr.slug, "--body", body }, function(err)
        if err then
          return vim.notify("parole: " .. err, vim.log.levels.ERROR)
        end
        vim.notify("parole: comment posted")
        if after then
          after()
        end
      end)
    end,
  })
end

local REPLY_MUTATION = [[
mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $threadId, body: $body }) {
    comment { id }
  }
}]]

---@param thread_id string GraphQL node id of the review thread
---@param after? fun()
function M.reply(thread_id, after)
  util.compose({
    title = "reply to thread",
    on_submit = function(body)
      gh.graphql(REPLY_MUTATION, { threadId = thread_id, body = body }, function(err)
        if err then
          return vim.notify("parole: " .. err, vim.log.levels.ERROR)
        end
        vim.notify("parole: reply posted")
        if after then
          after()
        end
      end)
    end,
  })
end

---Hand the PR to octo.nvim for a full inline review session.
---@param pr parole.Pr
function M.octo(pr)
  if vim.fn.exists(":Octo") ~= 2 then
    vim.notify("parole: octo.nvim is not installed", vim.log.levels.WARN)
    return
  end
  local ok, err = pcall(vim.cmd, "Octo " .. pr.url)
  if not ok then
    vim.notify("parole: octo handoff failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

return M
