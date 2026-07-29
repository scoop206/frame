# frame — demo tape for VHS (https://github.com/charmbracelet/vhs)
#
# Record it:   vhs assets/demo.tape        # writes assets/demo.gif
# Preview it:  vhs -o /tmp/demo.gif assets/demo.tape && open /tmp/demo.gif
#
# This records a real `frame wt` boot, so run it from a checkout of a project
# that already has a .frame/config.sh (see the Getting Started section). Set
# DEMO_DIR below to that project. The tape leaves the frame running at the end;
# tear it down afterward with `frame wt -d demo`.

# ── Output ────────────────────────────────────────────────────────────────
Output assets/demo.gif

# ── Terminal look (tuned to feel like Ghostty) ──────────────────────────────
Require frame                 # fail early if frame isn't on PATH
Set Shell        zsh          # frame needs zsh
Set FontSize     18
Set Width        1200
Set Height       700
Set Padding      24
Set Theme        "Catppuccin Mocha"
Set TypingSpeed  60ms
Set WindowBar    Colorful     # rounded title-bar chrome, close to Ghostty

# ── Scene 1: land in a project ──────────────────────────────────────────────
# Point this at any project that has a .frame/config.sh.
Hide
Type "cd ~/git_repos/your-project" Enter
# Let `#` lines read as on-screen narration instead of erroring — interactive
# zsh runs `#` as a command ("command not found: #") unless this is set.
Type "setopt interactive_comments" Enter
Type "clear" Enter
Show

Sleep 800ms
Type "# one command per feature: branch + worktree + neovim + Claude"
Sleep 1s
Enter
Sleep 500ms

# ── Scene 2: boot a frame ───────────────────────────────────────────────────
Type "frame wt demo"
Sleep 600ms
Enter

# Give frame time to create the worktree, run stack_up(), and open neovim
# with the Claude buffer in the foreground. Bump this if your stack is slow.
Sleep 6s

# Let the Claude buffer sit in view for a beat.
Sleep 2s

# ── Scene 3: reveal the parallel buffers ────────────────────────────────────
# The payoff: one frame is running several named buffers you can tell apart.
# The claude buffer starts focused and in terminal-insert mode, so leave it
# first — a bare Escape would go to Claude, not neovim:
Ctrl+\
Ctrl+n
Sleep 600ms

# Pop the buffer picker (space = leader, <leader>b):
Space
Type "b"
Sleep 2s

# Hop to the server buffer (cargo running) — filter by typing, then Enter.
# Tune the filter text/Enter to match how your picker behaves:
Type "server" Enter
Sleep 2.5s

# ...and over to vite, to show the buffers are live and independent. Re-assert
# normal mode first: landing in the server terminal may have entered insert
# mode (a startinsert autocmd), which would eat the leader. No-op otherwise:
Ctrl+\
Ctrl+n
Space
Type "b"
Sleep 1.5s
Type "vite" Enter
Sleep 2.5s

# ── Alternative reveal: no picker, frame-only gestures ──────────────────────
# If you ever want a version that leans on nothing but what frame injects:
#   Ctrl+\
#   Ctrl+n
#   Type ":ls" Enter          # lists claude, vite, server, local
#   Sleep 2.5s
#   Type ":b server" Enter    # hop to one
#   Sleep 2.5s

# ── End ─────────────────────────────────────────────────────────────────────
# Recording stops here with the frame still up. Tear it down after:
#   frame wt -d demo
