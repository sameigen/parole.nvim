# Regenerate the README demo GIF with vhs (charmbracelet/vhs):
#   cd parole.nvim && vhs scripts/demo/demo.tape
# Fully scripted + deterministic (scripts/demo/demo.lua): the real board, case
# file and quick-diff over canned GitHub responses — no network, gh, or real PRs.
Output "assets/demo.gif"
Output "assets/demo.mp4"
Require nvim

Set Shell "bash"
Set FontSize 20
Set Width 1280
Set Height 720
Set Padding 16
Set Margin 28
Set MarginFill "#1d2021"
Set BorderRadius 10
Set WindowBar Colorful
Set WindowBarSize 36
Set Theme "GruvboxDark"

# launch off-camera so startup flicker isn't recorded; the .lua self-drives
Hide
Type 'nvim --clean --cmd "set rtp+=." -c "luafile scripts/demo/demo.lua"'
Enter
Sleep 900ms
Show

# board -> case file -> quick diff -> inline comment (demo :qa at ~13s)
Sleep 11800ms
