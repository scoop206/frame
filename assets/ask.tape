# frame — "ask" clip for the landing page (site/clips/ask.*)
#
# Select lines in neovim, ask this frame's claude about them with
# :'<,'>FrameClaude (mapped to <leader>L in the demo's init.lua).
# Build the sandbox once with assets/clips/make-demo-home.sh (demo repos and
# demo sessions, never your real ~/.claude/projects), then record from the
# repo root with:  assets/clips/record.sh assets/ask.tape

Output site/clips/ask.mp4
Output site/clips/ask.webm

Require frame
Set Shell        zsh
Set FontSize     18
Set Width        1200
Set Height       680
Set Padding      20
Set Theme        "Catppuccin Mocha"
Set TypingSpeed  55ms
Set WindowBar    Colorful

Hide
Type "setopt interactive_comments; PROMPT='%F{208}❯%f '; cd ~/code/acme-api && frame shell review && clear" Enter
Sleep 25s
# leave claude's terminal, open the file under review
Ctrl+\
Ctrl+n
Type ":e src/webhooks.ts" Enter
Sleep 800ms
Show

Sleep 1.2s
Type "13G"
Sleep 500ms
Type "V"
Sleep 300ms
Type "j"
Sleep 900ms
Space
Type "L"
Sleep 700ms
Type "Why do we retry a 502 here? Could that charge twice?"
Sleep 900ms
Enter
Sleep 22s
