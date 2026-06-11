-- CI smoke test: every module loads, setup merges config, parsing works.
local modules = {
  "parole",
  "parole.gh",
  "parole.repos",
  "parole.util",
  "parole.board",
  "parole.case",
  "parole.actions",
  "parole.diff",
  "parole.worktree",
  "parole.agent",
  "parole.picker",
  "parole.health",
}
for _, m in ipairs(modules) do
  local ok, err = pcall(require, m)
  if not ok then
    io.stderr:write(("FAIL %s: %s\n"):format(m, err))
    os.exit(1)
  end
end

local parole = require("parole")
parole.setup({ owners = { "acme" }, keymaps = { board = { close = "x", refresh = false } } })
assert(parole.config.owners[1] == "acme")
assert(parole.config.limit == 50, "defaults must survive partial setup")
assert(parole.config.keymaps.board.close == "x", "keymap override applies")
assert(parole.config.keymaps.board.refresh == false, "keymap can be disabled")
assert(parole.config.keymaps.board.open_case == "<CR>", "untouched keymaps keep defaults")
assert(parole.config.keymaps.case.approve == "a", "case keymaps keep defaults")

-- validation rejects malformed config
assert(not pcall(parole.setup, { owners = "acme-org" }), "owners as string must fail")
assert(not pcall(parole.setup, { refresh_interval = -5 }), "negative interval must fail")
assert(not pcall(parole.setup, { keymaps = { board = { open_case = 7 } } }), "numeric keymap must fail")
assert(not pcall(parole.setup, { keymaps = { board = { teleport = "t" } } }), "unknown action must fail")
assert(pcall(parole.setup, { keymaps = { board = { refresh = false } } }), "false keymap is valid")
assert(not pcall(parole.setup, { agent = { use = "codex" } }), "unknown profile must fail")
assert(not pcall(parole.setup, { agent = { yolo = "yes" } }), "non-boolean lever must fail")
assert(not pcall(parole.setup, { agent = { profiles = { claude = { cmd = {} } } } }), "empty profile cmd must fail")

-- agent command assembly: levers are off by default and additive when pulled
local build = require("parole.agent").build_cmd
parole.setup({})
local cmd = build({ headless = false }, "do the thing")
assert(cmd[1] == "claude" and cmd[#cmd] == "do the thing")
assert(not vim.list_contains(cmd, "--dangerously-skip-permissions"), "yolo must be OFF by default")
assert(not vim.list_contains(cmd, "--permission-mode"), "auto must be OFF by default")
parole.setup({ agent = { yolo = true } })
assert(vim.list_contains(build({ headless = false }, "x"), "--dangerously-skip-permissions"), "yolo lever adds flag")
parole.setup({ agent = { auto = true } })
cmd = build({ headless = true }, "x")
assert(vim.list_contains(cmd, "--permission-mode"), "auto lever adds flag")
assert(vim.list_contains(cmd, "-p"), "headless flags applied")
parole.setup({
  agent = { use = "codex", profiles = { codex = { cmd = { "codex" }, headless = { "exec" } } } },
})
cmd = build({ headless = true }, "x")
assert(cmd[1] == "codex" and vim.list_contains(cmd, "exec"), "custom profile dispatches")
parole.setup({})

-- <Plug> mappings exist for every action
for action in pairs(require("parole.keys").descriptions) do
  local plug = require("parole.keys").plug(action)
  assert(vim.fn.maparg(plug, "n") ~= "", "missing mapping for " .. plug)
end

-- diff position mapping: unified diff line -> (path, line, side)
local diff_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, {
  "diff --git a/foo.txt b/foo.txt", -- 1
  "index 1234567..89abcde 100644", -- 2
  "--- a/foo.txt", -- 3
  "+++ b/foo.txt", -- 4
  "@@ -10,4 +10,5 @@ some context", -- 5
  " context line", -- 6: old 10 / new 10
  "-removed line", -- 7: old 11
  "+added line", -- 8: new 11
  "+added line two", -- 9: new 12
  " trailing context", -- 10: old 12 / new 13
})
local locate = require("parole.diff").locate
local function expect(lnum, path, line, side)
  local pos = locate(diff_buf, lnum)
  assert(pos, "locate returned nil for line " .. lnum)
  assert(
    pos.path == path and pos.line == line and pos.side == side,
    ("locate(%d) = %s:%d %s, expected %s:%d %s"):format(lnum, pos.path, pos.line, pos.side, path, line, side)
  )
end
expect(6, "foo.txt", 10, "RIGHT")
expect(7, "foo.txt", 11, "LEFT")
expect(8, "foo.txt", 11, "RIGHT")
expect(9, "foo.txt", 12, "RIGHT")
expect(10, "foo.txt", 13, "RIGHT")
assert(locate(diff_buf, 5) == nil, "hunk header is not commentable")
assert(locate(diff_buf, 2) == nil, "file header is not commentable")

local owner, repo, num = parole.parse_pr_arg("acme/widgets#7")
assert(owner == "acme" and repo == "widgets" and num == 7)
owner, repo, num = parole.parse_pr_arg("https://github.com/acme/widgets/pull/42")
assert(owner == "acme" and repo == "widgets" and num == 42)
assert(parole.parse_pr_arg("nonsense") == nil)

print("smoke OK")
