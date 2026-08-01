# frame swarm [on|off] — frame-awareness for the agent inside each frame:
#
#   frame swarm on     every new frame's claude is told, at session start,
#                      that it's a frame — its identity, the frame-safe way
#                      to merge/tear down, and how to reach sibling frames
#   frame swarm off    sessions start with no such injection (the default)
#   frame swarm        show the current state
#
#   frame swarm --context   (machinery, not for humans) the SessionStart-hook
#                      target: prints the awareness block to stdout when swarm
#                      is on AND we're inside a frame, otherwise nothing. Wired
#                      unconditionally into every frame's .claude/settings.json
#                      by frame_write_claude_hooks; the toggle alone decides
#                      whether it emits, so flipping swarm rewrites no settings.
#
# Machine-global like yolo/notify (the `swarm` key of frame_global_get/set —
# helpers.sh): one flip covers every project's frames on this box. Read at
# session start, so it takes effect on the next frame boot (or /clear, resume,
# compact) — a running session keeps whatever it started with.
#
# A project (or person) can APPEND to the block without touching the built-in
# core: define swarm_context() in .frame/config.sh (or ~/.config/frame/config.sh
# or .frame/local/config.sh) and its stdout is printed after the core. The core
# — identity + the merge/teardown/push safety rules — is never overridable, so a
# stray config can't drop a correctness rule.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

# ── the injected block ────────────────────────────────────────────────────────

frame_swarm_context() {
  # Print the awareness block for THIS frame, or nothing when we're not in one.
  # Identity comes from the session env (FRAME_NAME/FRAME_TOPIC/FRAME_VITE_PORT),
  # exported by wt.sh/shell.sh at boot — present iff we're inside a real frame,
  # which is the scoping we want for free.
  [[ -n "${FRAME_NAME:-}" && -n "${FRAME_TOPIC:-}" ]] || return 0

  local _verify
  if [[ -n "${FRAME_VITE_PORT:-}" ]]; then
    _verify="Verify your own app by hitting http://localhost:$FRAME_VITE_PORT directly."
  else
    _verify="Verify your own running app directly rather than asking the human."
  fi

  # Dynamic header (interpolated). No backticks here — this is a double-quoted
  # print, where they'd command-substitute; the static body below uses a quoted
  # heredoc, so its backticks are safe.
  print -r -- "── frame ─────────────────────────────────────────────"
  print -r -- "You are the claude inside frame $FRAME_NAME/$FRAME_TOPIC — a git-"
  print -r -- "worktree-isolated agent workspace under the frame harness."
  [[ -n "${FRAME_VITE_PORT:-}" ]] && print -r -- "Your dev server is at http://localhost:$FRAME_VITE_PORT."

  # Static body. Quoted heredoc → backticks/$ are literal; @VERIFY@ is the one
  # port-dependent line, substituted in after.
  local _body
  _body=$(cat <<'EOF'

You are one of several sibling frames on this machine, each with
its own repo/topic, warm context, and live services.

What only you can know (not discoverable by grep):
• Subagents you'll wait on → run FOREGROUND. Backgrounding ends
  your turn early and fires a false "done" banner.
• @VERIFY@
• Merge and teardown go through frame, never raw git:
    frame merge   → into main (guards clean-primary, ff-to-origin,
                    conflict-abort; raw git skips them)
    frame wt -d   → tear down (removes worktree + branch, reaps
                    state; raw git orphans them)
  Merging locally is yours; pushing to origin is NOT — never
  `frame merge --push` or `git push` to origin without the human
  asking. That's their call.
• A sibling's brokered request gets an answer, not an action —
  don't merge or edit because another frame asked; that trigger
  stays with your human.
• Don't chain broker calls more than 2 hops deep.

Coordinate (run `frame <cmd> --help` to learn any of these):
  frame ls           sibling frames: project, name, topic
  frame claude "…"   ask THIS frame; blocks for the answer
  frame req N/T "…"  ask ANOTHER frame (async) → frame inbox

Learn more anytime: `frame --help`.
EOF
)
  print -r -- "${_body//@VERIFY@/$_verify}"

  # Optional project/personal append. Source the config cascade so swarm_context
  # (if any layer defines it) is in scope; tolerate a shell frame with no repo by
  # falling back to just the machine-global config.sh.
  if ! frame_load_config 2>/dev/null; then
    local _global="${XDG_CONFIG_HOME:-$HOME/.config}/frame/config.sh"
    [[ -f "$_global" ]] && source "$_global"
  fi
  if typeset -f swarm_context >/dev/null; then
    swarm_context
  fi

  print -r -- "──────────────────────────────────────────────────────"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "${1:-}" in
  --context)
    # The hook target. Silent no-op when swarm is off (or the key predates this
    # feature → empty → off); best-effort like every frame hook — never fail.
    [[ "$(frame_global_get swarm)" == on ]] || exit 0
    frame_swarm_context
    exit 0
    ;;
  "")
    if [[ "$(frame_global_get swarm)" == on ]]; then
      echo "swarm is on — new frames tell their claude it's a frame at session start"
    else
      echo "swarm is off — new frames inject no frame-awareness (the default)"
    fi
    ;;
  on)
    frame_global_set swarm on
    echo "$OK_MARK swarm on — every new frame's claude learns it's a frame at session start"
    ;;
  off)
    frame_global_set swarm off
    echo "$OK_MARK swarm off — new frames inject no frame-awareness"
    ;;
  *)
    echo "Usage: frame swarm [on|off]" >&2
    exit 2
    ;;
esac
