# VHS tape for the Stanza demo GIF. Regenerate with: vhs assets/demo.tape
# (requires `vhs` and built stanza-demo, stanza-menu, stanza-async, and
# stanza-wrap under ./zig-out/bin)
# Four scenes: hints/completion/search/vi · completion menu chaining on one
# line · async output above the prompt · wrapped multi-line editing.

Output assets/demo.gif

Set Shell "bash"
Set FontSize 20
Set Width 1100
Set Height 660
Set Padding 24
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set TypingSpeed 65ms

# --- scene 1: ghost hints, Tab completion, Ctrl-R search, vi editing ---
Hide
Type "clear" Enter
Type "./zig-out/bin/stanza-demo" Enter
Sleep 1s
Show

Sleep 900ms
Type "co"
Sleep 900ms
Type "mm"
Sleep 500ms
Tab
Sleep 700ms
Enter
Sleep 700ms
Ctrl+R
Sleep 600ms
Type "com"
Sleep 900ms
Enter
Sleep 800ms
Type "ppush"
Sleep 700ms
Escape
Sleep 500ms
Type "0"
Sleep 400ms
Type "x"
Sleep 900ms
Enter
Sleep 900ms

Ctrl+D
Sleep 800ms

# --- scene 2: the completion menu, chaining arguments on one line ---
Hide
Type "clear" Enter
Type "./zig-out/bin/stanza-menu" Enter
Sleep 1s
Show

Sleep 800ms
Type "si"
Sleep 500ms
Tab
Sleep 600ms
Tab
Sleep 700ms
Tab
Sleep 700ms
Enter
Sleep 500ms
Type " li"
Sleep 500ms
Tab
Sleep 600ms
Tab
Sleep 700ms
Down
Sleep 700ms
Enter
Sleep 500ms
Enter
Sleep 1s

Ctrl+D
Sleep 800ms

# --- scene 3: asynchronous output printing above the line being edited ---
Hide
Type "clear" Enter
Type "./zig-out/bin/stanza-async" Enter
Sleep 1s
Show

Sleep 600ms
Type "deploy prod"
Sleep 2600ms
Type " --now"
Sleep 600ms
Enter
Sleep 1100ms

Ctrl+D
Sleep 800ms

# --- scene 4: a long line wraps; cursor moves between rows ---
Hide
Type "clear" Enter
Type "./zig-out/bin/stanza-wrap" Enter
Sleep 1s
Show

Sleep 800ms
Type "this is a deliberately long command line, much wider than the window, so Stanza wraps it across rows"
Sleep 1100ms
Ctrl+A
Sleep 900ms
Ctrl+E
Sleep 900ms
Type " — and back"
Sleep 800ms
Enter
Sleep 1000ms

Ctrl+D
Sleep 1500ms
