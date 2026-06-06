# VHS tape for the Stanza demo GIF. Regenerate with: vhs assets/demo.tape
# (requires `vhs` and a built ./zig-out/bin/stanza-demo and ./zig-out/bin/stanza-wrap)
# One recording: the single-line demo, then the multi-line example.

Output assets/demo.gif

Set Shell "bash"
Set FontSize 20
Set Width 1100
Set Height 660
Set Padding 24
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set TypingSpeed 65ms

# --- single-line: completion, hints, highlight, vi, history search ---
Hide
Type "cd ." Enter
Type "rm -f .stanza_demo_history; clear" Enter
Type "./zig-out/bin/stanza-demo" Enter
Sleep 1s
Show

Sleep 800ms
Type "comm"
Sleep 1s
Tab
Sleep 800ms
Type " -m hello"
Sleep 600ms
Enter
Sleep 800ms

Type "stat"
Sleep 900ms
Tab
Sleep 700ms
Enter
Sleep 800ms

# vi mode: fix a typo in normal mode (the cursor turns into a block)
Type "pushh"
Sleep 700ms
Escape
Sleep 800ms
Type "x"
Sleep 800ms
Enter
Sleep 900ms

# reverse incremental history search
Ctrl+R
Sleep 700ms
Type "comm"
Sleep 1s
Enter
Sleep 900ms

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
