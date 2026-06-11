# Contributing to parole.nvim

Thanks for taking a look. PRs and issues welcome.

## Scope

parole is a cross-repo GitHub PR board for Neovim built around the
vim-fugitive workflow. It composes with `gh`, octo.nvim, and diffview.nvim
rather than reimplementing inline review.

## Development

Dev-link the repo, then:

```sh
nvim --clean --cmd "set rtp+=." -l scripts/smoke.lua   # modules load, config + validation, diff position mapping
stylua --check lua/ scripts/                            # formatting (run `stylua lua/ scripts/` to fix)
```

CI runs stylua + the smoke suite. Write-path changes are best verified against
a throwaway PR in a private sandbox repo, never a real one.

## Conventions

- `setup()` is optional and validates its input; every buffer-local key is
  configurable (`false` disables) and also exposed as `<Plug>(parole-<action>)`.
- Async GitHub calls go through `parole.gh` (`json`/`run`/`graphql`); board
  refreshes use a generation token so stale responses can't clobber newer state.
- LuaCATS annotations on public functions. No `Co-Authored-By` trailers.

## Regenerating the demo GIF

`scripts/demo.sh` (needs `asciinema` + `agg`). Fully scripted and
deterministic — `gh` is stubbed, no real PRs touched.
