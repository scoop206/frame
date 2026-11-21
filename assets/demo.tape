# frame — the hero demo (assets/demo.gif for the README, site/clips/hero.* for
# the landing page). One frame on a real Astro project: claude, a shell and the
# dev server as neovim buffers, and a question carried from the code to claude.
#
# Recorded in a local clone of pdoomtracker inside a sandbox HOME
# (~/git_repos/pdoomtracker there, origin removed, node_modules copied, no .env)
# whose nvim config and plugins are symlinks to the real ones, so the editor is
# the real setup while claude starts clean and paths print as ~/…, never your
# username. From the frame repo root:
#   DEMO_HOME=/Users/Shared/frame-demo-hero assets/clips/record.sh assets/demo.tape
# then tear the frame down:  frame wt -d shorter-lead  (same HOME).
# Hide/Show cut out the waits (and frame's boot lines, which print paths).

Output assets/demo.gif
Output site/clips/hero.mp4
Output site/clips/hero.webm

Require frame
Set Shell        zsh
Set FontSize     17
Set Width        1280
Set Height       740
Set Padding      20
Set Theme        "Catppuccin Mocha"
Set TypingSpeed  50ms
Set WindowBar    Colorful

Hide
Type "setopt interactive_comments; PROMPT='%F{208}❯%f '; cd ~/git_repos/pdoomtracker && clear" Enter
Sleep 600ms
Show

# ── one command: branch + worktree + neovim + claude + astro dev ────────────
Sleep 600ms
Type "# one frame per topic: a worktree, neovim, claude and the dev server"
Sleep 500ms
Enter
Type "frame wt shorter-lead"
Sleep 500ms
Enter
Hide
Sleep 35s
Show

# ── talk to claude in its buffer ─────────────────────────────────────────────
Sleep 1.5s
Type "the homepage lead paragraph runs long. give me two tighter versions, no edits yet"
Sleep 600ms
Enter
Sleep 4s
Hide
Sleep 35s
Show
Sleep 4s

# ── the dev server is just another buffer ───────────────────────────────────
Ctrl+\
Ctrl+n
Space
Type "b"
Sleep 1.5s
Type "vite"
Sleep 600ms
Enter
Sleep 3.5s

# ── carry a selection from the code to claude ───────────────────────────────
Ctrl+\
Ctrl+n
Space
Type "f"
Sleep 1.2s
Type "pages/index.astro"
Sleep 800ms
Enter
Sleep 1.2s
Type `/class="lead"`
Enter
Sleep 800ms
Type "jVj"
Sleep 1s
Space
Type "l"
Sleep 600ms
Type "use your first version here"
Sleep 700ms
Enter
Sleep 4s
Hide
Sleep 30s
Show
Sleep 3s

# ── back in the file: the edit is there ─────────────────────────────────────
Ctrl+\
Ctrl+n
Ctrl+w
Type "h"
Type ":e" Enter
Sleep 4s
