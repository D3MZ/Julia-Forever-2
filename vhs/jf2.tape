# Deterministic, credential-free terminal evidence for scheduled agent review.
# Run from repository root after precompiling the Julia app.
Require julia
Set Shell bash
Set FontFamily "JetBrains Mono"
Set FontSize 18
Set Width 1200
Set Height 720
Set TypingSpeed 50 ms
Set CursorBlink false

Output artifacts/vhs/jf2-terminal.ascii

Type "./bin/jf2"
Enter
Sleep 6 s
Screenshot artifacts/vhs/chat.png

Type "/settings"
Enter
Sleep 2 s
Screenshot artifacts/vhs/settings.png

Ctrl+C
Sleep 1 s
Type "./bin/jf2"
Enter
Sleep 5 s
Type "/"
Sleep 1 s
Screenshot artifacts/vhs/slash-menu.png
Ctrl+C
