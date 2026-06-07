# VHS tape for the Stanza demo GIF. Regenerate with: vhs assets/demo.tape
# (requires `vhs` and built ./zig-out/bin/stanza-menu and ./zig-out/bin/stanza-wrap)
# One recording: menu completion, then the multi-line example.

Output assets/demo.gif

Set Shell "bash"
Set FontSize 20
Set Width 1100
Set Height 660
Set Padding 24
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set TypingSpeed 65ms

# --- single-line: menu completion and line-aware argument completion ---
Hide
Type "clear" Enter
Type "./zig-out/bin/stanza-menu" Enter
Sleep 1s
Show

Sleep 800ms
Type "li"
Sleep 600ms
Tab
Sleep 600ms
Tab
Sleep 600ms
Tab
Sleep 600ms
Enter
Sleep 500ms
Tab
Sleep 700ms
Enter
Sleep 500ms
Enter
Sleep 900ms

Type "size "
Sleep 600ms
Tab
Sleep 600ms
Tab
Sleep 600ms
Enter
Sleep 500ms
Enter
Sleep 800ms

Ctrl+D
Sleep 1s

# --- multi-line: a long line wraps; cursor moves between rows ---
Hide
Type "clear" Enter
Type "./zig-out/bin/stanza-wrap" Enter
Sleep 1s
Show

Sleep 800ms
Type "this is a deliberately long command line, much wider than the window, so Stanza wraps it across rows"
Sleep 1200ms
Ctrl+A
Sleep 1s
Ctrl+E
Sleep 1s
Type " — and back"
Sleep 800ms
Enter
Sleep 1100ms

Ctrl+D
Sleep 1500ms
