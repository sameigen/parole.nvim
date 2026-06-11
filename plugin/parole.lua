if vim.g.loaded_parole then
  return
end
vim.g.loaded_parole = true

if vim.fn.has("nvim-0.11") ~= 1 then
  vim.notify("parole.nvim requires Neovim >= 0.11", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("Parole", function(cmd)
  require("parole").open(cmd.args)
end, {
  nargs = "?",
  desc = "Open the parole board, or a case: :Parole owner/repo#123 | :Parole <pr url>",
})

vim.api.nvim_create_user_command("ParolePick", function()
  require("parole.picker").open()
end, { desc = "Pick a PR with fzf-lua" })

vim.api.nvim_create_user_command("ParoleAgent", function(cmd)
  require("parole.agent").dispatch_here({ headless = cmd.bang })
end, { bang = true, desc = "Dispatch a Claude Code agent in a fresh worktree of the current repo (! = headless)" })

vim.api.nvim_create_user_command("ParoleClean", function(cmd)
  require("parole.worktree").clean({ force = cmd.bang })
end, { bang = true, desc = "Remove parole-managed worktrees (skips dirty; ! forces)" })

-- <Plug>(parole-*) mappings: stable remap targets for every action.
for action, desc in pairs(require("parole.keys").descriptions) do
  vim.keymap.set("n", require("parole.keys").plug(action), function()
    require("parole.keys").run(action)
  end, { desc = "parole: " .. desc })
end
