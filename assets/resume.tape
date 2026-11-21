# frame — "resume" clip for the landing page (site/clips/resume.*)
#
# `frame shell --recent` → pick yesterday's session → it resumes in place and
# claude takes the latest update with its context intact.
# Build the sandbox once with assets/clips/make-demo-home.sh (demo repos and
# demo sessions, never your real ~/.claude/projects), then record from the
# repo root with:  assets/clips/record.sh assets/resume.tape

Output site/clips/resume.mp4
Output site/clips/resume.webm

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
Type "setopt interactive_comments; PROMPT='%F{208}❯%f '; cd ~/code/acme-api && clear" Enter
Sleep 500ms
Show

Sleep 600ms
Type "# pick up yesterday where you left off"
Sleep 700ms
Enter
Type "frame shell --recent"
Sleep 500ms
Enter
Sleep 2.5s
Down
Sleep 1.2s
Down
Sleep 1.2s
Up
Sleep 600ms
Up
Sleep 1.5s
Enter

# claude resumes inside the frame's neovim with the transcript in view
Sleep 9s
Type "processor team confirmed: a 502 can still capture the charge. go ahead with the idempotency key"
Sleep 800ms
Enter
Sleep 14s
