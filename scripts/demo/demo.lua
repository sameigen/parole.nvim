-- Scripted, reproducible demo for the README GIF: the real parole board and
-- quick-diff rendering canned GitHub responses, driven on a fixed timeline
-- that ends with :qa. No network, no gh, no real PRs — only parole.gh's two
-- entry points (json/run) are stubbed; every render path is the real thing.
--
-- See scripts/demo.sh for the asciinema/agg wrapper.

local gh = require("parole.gh")

-- ---------------------------------------------------------------------------
-- canned GitHub responses, keyed off the gh argv parole would have run.

local function pr(slug, number, title, author, age_h, draft)
  return {
    repository = { nameWithOwner = slug },
    number = number,
    title = title,
    author = { login = author },
    updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - age_h * 3600),
    url = ("https://github.com/%s/pull/%d"):format(slug, number),
    isDraft = draft or false,
  }
end

local SECTIONS = {
  ["--review-requested=@me"] = {
    pr("acme/api", 482, "fix(auth): refresh tokens before the 5-minute expiry window", "rhea", 2),
    pr("acme/web", 1190, "feat(settings): dark-mode toggle with system-preference default", "juno", 6),
  },
  ["--author=@me"] = {
    pr("acme/api", 480, "refactor(db): extract the migration runner into its own module", "you", 20),
    pr("acme/infra", 73, "chore(tf): bump the AWS provider to 5.x", "you", 26),
  },
  ["--involves=@me"] = {
    pr("acme/web", 1188, "fix(a11y): focus trap in the command palette", "milo", 30),
  },
}

local DIFF = table.concat({
  "diff --git a/src/auth/tokens.ts b/src/auth/tokens.ts",
  "index 8f2a1c3..b4d9e02 100644",
  "--- a/src/auth/tokens.ts",
  "+++ b/src/auth/tokens.ts",
  "@@ -34,9 +34,14 @@ export class TokenManager {",
  "   async getAccessToken(): Promise<string> {",
  "     const token = this.cache.get(ACCESS_KEY);",
  "-    if (token && !this.isExpired(token)) {",
  "+    // refresh a little early so an in-flight request never races expiry",
  "+    if (token && !this.isExpiringSoon(token)) {",
  "       return token.value;",
  "     }",
  "     return this.refresh();",
  "   }",
  "+",
  "+  private isExpiringSoon(token: Token): boolean {",
  "+    return token.expiresAt - Date.now() < REFRESH_WINDOW_MS;",
  "+  }",
  " }",
}, "\n")

local function has(args, needle)
  for _, a in ipairs(args) do
    if a == needle or (type(a) == "string" and a:find(needle, 1, true)) then
      return true
    end
  end
  return false
end

-- the full PR for the case file (#482)
local CASE = {
  number = 482,
  title = "fix(auth): refresh tokens before the 5-minute expiry window",
  body = "Tokens were refreshed only once expired, so a request in flight at the\nboundary could 401. This refreshes a little early.\n\n- adds `isExpiringSoon` (REFRESH_WINDOW_MS before expiry)\n- keeps the cache path; no API surface change",
  author = { login = "rhea" },
  baseRefName = "main",
  headRefName = "fix/token-refresh",
  state = "OPEN",
  isDraft = false,
  reviewDecision = "REVIEW_REQUIRED",
  statusCheckRollup = { { conclusion = "SUCCESS" }, { conclusion = "SUCCESS" } },
  additions = 8,
  deletions = 1,
  changedFiles = 1,
  labels = { { name = "auth" }, { name = "bug" } },
  commits = {
    {
      oid = "a1b2c3d4e5",
      messageHeadline = "refresh tokens before expiry, not after",
      authors = { { login = "rhea" } },
      committedDate = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 7200),
    },
    {
      oid = "b4d9e02c11",
      messageHeadline = "test: in-flight request at the expiry boundary",
      authors = { { login = "rhea" } },
      committedDate = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 5400),
    },
  },
  reviews = {},
  comments = {},
  url = "https://github.com/acme/api/pull/482",
  createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 7200),
  mergeable = "MERGEABLE",
}

gh.json = function(args, cb)
  if has(args, "search") and has(args, "prs") then
    for flag, list in pairs(SECTIONS) do
      if has(args, flag) then
        return cb(nil, list)
      end
    end
    return cb(nil, {})
  end
  if has(args, "headRefOid") then
    return cb(nil, { headRefOid = "b4d9e02c11a7" })
  end
  if has(args, "mergeable") then -- the case file's full `pr view`
    return cb(nil, CASE)
  end
  if has(args, "reviewDecision") then -- board enrichment
    local approved = has(args, "73") or has(args, "1188")
    return cb(nil, {
      reviewDecision = approved and "APPROVED" or "REVIEW_REQUIRED",
      statusCheckRollup = { { conclusion = "SUCCESS" } },
      headRefName = "fix/token-refresh",
      baseRefName = "main",
    })
  end
  cb(nil, {})
end

gh.graphql = function(_, _, cb) -- review threads for the case file
  cb(nil, {
    data = {
      repository = {
        pullRequest = {
          reviewThreads = {
            nodes = {
              {
                isResolved = false,
                isOutdated = false,
                path = "src/auth/tokens.ts",
                line = 37,
                comments = {
                  nodes = {
                    {
                      author = { login = "juno" },
                      createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 3600),
                      body = "Can we pull the 5m window into a named constant?",
                      diffHunk = "@@ -34,9 +34,14 @@\n-    if (token && !this.isExpired(token)) {\n+    if (token && !this.isExpiringSoon(token)) {",
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
  })
end

gh.run = function(args, cb)
  if has(args, "diff") then
    return cb(nil, DIFF)
  end
  cb(nil, "") -- the inline-comment POST: succeed silently
end

-- ---------------------------------------------------------------------------
-- parole, and an auto-filled comment body so the GIF needs no typing.

-- demo aesthetics: truecolor + a high-contrast built-in scheme (so the GIF
-- shows real editor colors, not agg's 16-color map), and no end-of-buffer ~.
vim.o.termguicolors = true
pcall(vim.cmd.colorscheme, "retrobox")
vim.opt.fillchars = { eob = " " }

require("parole").setup({
  owners = { "acme" },
  refresh_interval = 0,
  worktree_dir = vim.fn.tempname() .. "/parole-demo-wt", -- never the real cache
})
-- the board's open() sweeps merged/closed PR worktrees; with stubbed gh that
-- would touch real state, so disable it for the recording.
require("parole.worktree").sweep = function() end

local COMMENT = "Nice — early refresh closes the race. Worth a constant for the 5m window?"

-- ---------------------------------------------------------------------------
-- timeline: board -> quick diff -> inline comment on a hunk line.

local function cursor_to(pattern)
  local buf = vim.api.nvim_get_current_buf()
  for l = 1, vim.api.nvim_buf_line_count(buf) do
    if vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1]:find(pattern) then
      pcall(vim.api.nvim_win_set_cursor, 0, { l, 0 })
      return l
    end
  end
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "m", false)
end

local steps = {
  -- 1. the cross-repo board: PRs awaiting you / yours / involved, with checks
  {
    300,
    function()
      vim.cmd("Parole")
    end,
  },
  {
    1900,
    function()
      cursor_to("refresh tokens")
    end,
  },
  -- 2. open the case file: metadata, checks, commits, the open thread
  {
    2700,
    function()
      require("parole.case").open("acme", "api", 482)
    end,
  },
  -- 3. the quick diff for the change
  {
    5200,
    function()
      require("parole.diff").open({
        slug = "acme/api",
        owner = "acme",
        repo = "api",
        number = 482,
        title = CASE.title,
        url = CASE.url,
      })
    end,
  },
  {
    6800,
    function()
      cursor_to("^%+%s*if %(token") -- a changed line inside the hunk
    end,
  },
  -- 4. comment inline on that line
  {
    7700,
    function()
      press("c")
    end,
  },
  {
    8800,
    function()
      local buf = -1
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b):find("comment on", 1, true) then
          buf = b
        end
      end
      if buf ~= -1 then
        vim.api.nvim_set_current_buf(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { COMMENT })
      end
    end,
  },
  {
    10500,
    function()
      vim.cmd("stopinsert")
      vim.cmd("write")
    end,
  },
  {
    13000,
    function()
      vim.cmd("qa!")
    end,
  },
}

for _, step in ipairs(steps) do
  vim.defer_fn(step[2], step[1])
end
