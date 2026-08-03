# Frame helper library (zsh). Sourced by bin/frame before any command runs,
# so every function here is also available inside a project's .frame/config.sh
# (stack_up / app_env hooks).

FRAME_SERVICES_COMPOSE="$FRAME_ROOT/services/docker-compose.yml"

# ── runtime dir ─────────────────────────────────────────────────────────────
# One per-user home for this session's ephemera — nvim sockets, prompt/gtab
# stamps, teardown logs, the workers-window record — instead of strewing them
# across /tmp's root. Grouped so `ls "$FRAME_RUNDIR"` is legible and
# `rm -rf "$FRAME_RUNDIR"` resets all frame runtime state. Exported so the nvim
# layout (session.lua) and any child resolve the same path; overridable so the
# test sandbox can point it at a private, per-test dir.
#
# Unlike /tmp itself, /tmp/frame is NOT guaranteed to exist: macOS's daily
# tmp_cleaner reaps files untouched for ~3 days and can then remove the emptied
# dir. So writers go through frame_rundir(), which (re)creates it first. 0700
# both tidies and sidesteps the world-writable-/tmp pre-creation footgun.
: ${FRAME_RUNDIR:=/tmp/frame}
export FRAME_RUNDIR

frame_rundir() {
  # Ensure $FRAME_RUNDIR exists and print it. Use at every write site; reads and
  # globs can reference $FRAME_RUNDIR directly (a missing dir just yields no
  # matches / a false -S test, which is the correct answer).
  [[ -d $FRAME_RUNDIR ]] || mkdir -m 700 -p -- "$FRAME_RUNDIR"
  print -r -- "$FRAME_RUNDIR"
}

# ── status markers ────────────────────────────────────────────────────────────
# Colored only when the stream is a terminal (✗ prints to stderr, ✓/▶/⚠ to
# stdout) and NO_COLOR is unset — piped output, logs, and the session.lua
# teardown watcher keep seeing the bare characters. Each marker is gated on the
# stream it actually prints to, so redirecting the other one doesn't drop color.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  X_MARK=$'\e[1;31m✗\e[0m'
else
  X_MARK='✗'
fi
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  OK_MARK=$'\e[32m✓\e[0m'
  RUN_MARK=$'\e[36m▶\e[0m'
  WARN_MARK=$'\e[1;33m⚠\e[0m'
else
  OK_MARK='✓'
  RUN_MARK='▶'
  WARN_MARK='⚠'
fi

# ── project discovery ─────────────────────────────────────────────────────────

frame_project_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

frame_main_wt() {
  # The primary checkout: first entry in `git worktree list`.
  git -C "${1:-.}" worktree list --porcelain | head -1 | cut -d' ' -f2
}

frame_load_config() {
  # Sets PROJECT_ROOT, MAIN_WT, NAME, PORT_PREFIX, plus whatever the project
  # config defines (SERVER_CMD, ports, stack_up, app_env, …).
  #
  # Config lookup order — first hit wins:
  #   <this checkout>/.frame/local/config.sh   (personal, gitignored)
  #   <this checkout>/.frame/config.sh         (committed project facts)
  #   <primary checkout>/.frame/…              (fallback: a worktree created
  #                                             before .frame was committed)
  PROJECT_ROOT=$(frame_project_root) || {
    echo "$X_MARK frame: not inside a git repository" >&2
    return 1
  }
  MAIN_WT=$(frame_main_wt "$PROJECT_ROOT")

  # Machine-wide base layer: personal hooks (e.g. merge_epilog) shared by every
  # project on this box, in XDG-standard ~/.config/frame/config.sh. Sourced
  # BEFORE the project config so any project can override or unset what it
  # defines. Opt-in and sourced — unlike $FRAME_GLOBAL_CONFIG (key=value, never
  # sourced so hot-path reads execute nothing).
  local _global="${XDG_CONFIG_HOME:-$HOME/.config}/frame/config.sh"
  [[ -f "$_global" ]] && source "$_global"

  local _dir _f _cfg=""
  for _dir in "$PROJECT_ROOT" "$MAIN_WT"; do
    for _f in "$_dir/.frame/local/config.sh" "$_dir/.frame/config.sh"; do
      if [[ -f "$_f" ]]; then _cfg=$_f; break 2; fi
    done
  done
  if [[ -n "$_cfg" ]]; then
    source "$_cfg"
  fi

  # NAME defaults to the primary checkout's directory name; PORT_PREFIX is the
  # env-var prefix the project's own code reads (e.g. FLIPNEM_VITE_PORT).
  : "${NAME:=${MAIN_WT:t}}"
  : "${PORT_PREFIX:=${(U)NAME//-/_}}"
}

frame_self_identity() {
  # Sets SELF_NAME / SELF_TOPIC to THIS frame's own identity — used as a reply
  # return address by `frame agent` (arming) and as the socket to read by
  # `frame reply` / `frame inbox`. Same derivation as status.sh: a shell frame
  # (no git repo) carries it in the session env; a checkout derives it from the
  # worktree dir (_NAME-TOPIC) or the current branch. Returns 1 with SELF_* unset
  # when not inside any frame — the caller decides whether that's fatal.
  if ! frame_project_root >/dev/null \
      && [[ -n "${FRAME_NAME:-}" && -n "${FRAME_TOPIC:-}" ]]; then
    SELF_NAME=$FRAME_NAME SELF_TOPIC=$FRAME_TOPIC
    return 0
  fi
  frame_load_config 2>/dev/null || return 1
  SELF_NAME=$NAME
  if [[ "${PROJECT_ROOT:t}" == _$NAME-* ]]; then
    SELF_TOPIC="${${PROJECT_ROOT:t}#_$NAME-}"
  else
    SELF_TOPIC=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null) \
      || return 1
  fi
  return 0
}

frame_session_down_hint() {
  # frame_session_down_hint NAME TOPIC — print a diagnostic second line (stderr)
  # after a "no socket at …" error, naming the LIKELY CAUSE and its fix. A
  # frame's inbox, broker and title all live in its nvim session; the commands
  # that read them (inbox, claude, status, view, req's return address) resolve an
  # identity and then find no socket — but "no socket" has two very different
  # causes, and the raw line doesn't say which. The tell is the session env:
  # frame shell (shell.sh) and frame wt (wt.sh) both export FRAME_NAME/FRAME_TOPIC
  # at boot, so every terminal INSIDE a live frame carries them. Absent → the
  # caller is at a bare shell that merely cd'd into the NAME/TOPIC checkout, so
  # frame_self_identity derived NAME/TOPIC from git and there was never a session
  # here to hold anything (the common "doing comms from a bare CLI" mistake — the
  # operator commands from inside a frame, not a bare shell). Present → a real
  # session that has since exited.
  local _name=$1 _topic=$2
  if [[ -z "${FRAME_NAME:-}" || -z "${FRAME_TOPIC:-}" ]]; then
    echo "  You're at a bare shell in the $_name/$_topic checkout, not inside a" >&2
    echo "  running frame — a frame's inbox and broker live in its nvim session," >&2
    echo "  and there isn't one here. Boot one for this checkout (frame wt), or a" >&2
    echo "  branchless home frame to command from (frame shell <topic>), then run" >&2
    echo "  this from inside it." >&2
  else
    echo "  This frame's session isn't running — reboot it (frame wt $_topic)." >&2
  fi
}

# ── machine-global config ─────────────────────────────────────────────────────
# ~/.local/share/frame/config — key=value settings that apply to every
# project's frames on this machine (notify=on|off, the global banner switch;
# yolo=on|off, the claude permissions switch). Under $HOME
# rather than FRAME_ROOT because, like the notifier app, machine state must
# not shift between frame worktrees. Plain key=value rather than sourced
# shell so hook-path reads never execute anything.

FRAME_GLOBAL_CONFIG="$HOME/.local/share/frame/config"

frame_global_get() {
  # frame_global_get KEY — print KEY's value, empty if the file or key is
  # absent (callers treat empty as the default). Last occurrence wins.
  local -a _hits
  [[ -f "$FRAME_GLOBAL_CONFIG" ]] || return 0
  _hits=(${(M)${(@f)"$(<$FRAME_GLOBAL_CONFIG)"}:#$1=*})
  (( $#_hits )) && print -r -- "${_hits[-1]#*=}"
  return 0
}

frame_global_set() {
  # frame_global_set KEY VALUE — update KEY in place (comments, blank lines,
  # and other keys survive) or append it; the first write creates the file.
  local _k=$1 _v=$2 _i _found=0
  local -a _lines
  mkdir -p "${FRAME_GLOBAL_CONFIG:h}"
  if [[ ! -f "$FRAME_GLOBAL_CONFIG" ]]; then
    print -r -- "# frame settings for every project on this machine (key=value)." \
      > "$FRAME_GLOBAL_CONFIG"
  fi
  _lines=("${(@f)$(<$FRAME_GLOBAL_CONFIG)}")
  for (( _i=1; _i <= $#_lines; _i++ )); do
    if [[ "$_lines[_i]" == $_k=* ]]; then
      _lines[_i]="$_k=$_v"
      _found=1
    fi
  done
  (( _found )) || _lines+=("$_k=$_v")
  print -rl -- "${_lines[@]}" > "$FRAME_GLOBAL_CONFIG"
}

frame_export_claude_flags() {
  # The claude buffer's command (buffers.json) reads ${FRAME_CLAUDE_FLAGS}.
  # Empty — plain `claude`, normal permission prompts — unless the machine's
  # yolo switch is on (`frame yolo on`), which adds
  # --dangerously-skip-permissions to every frame's claude. Called by each
  # boot path (wt.sh, shell.sh) just before exec'ing the layout.
  if [[ "$(frame_global_get yolo)" == on ]]; then
    export FRAME_CLAUDE_FLAGS="--dangerously-skip-permissions"
  else
    export FRAME_CLAUDE_FLAGS=""
  fi
}

# ── dependency preflight ──────────────────────────────────────────────────────
# Frame shells out to its dependencies with no upfront check, so a missing one
# fails deep inside with a raw "command not found": no nvim fails the `exec`
# outright, and no claude leaves its buffer at a bare shell while the frame
# never reports ready (FrameReady waits for a claude prompt that never renders).
# The boot paths (wt.sh, shell.sh) call frame_require just before exec'ing nvim
# so the frame refuses up front, naming the dep and how to install it, instead
# of coming up half-alive.

frame_dep_hint() {
  # frame_dep_hint CMD — one-line "how to get it" for a missing dependency.
  case "$1" in
    zsh)    print -r -- "the shell frame runs on — ships with macOS; else 'brew install zsh'" ;;
    git)    print -r -- "'brew install git', or 'xcode-select --install'" ;;
    nvim)   print -r -- "neovim, frame's buffer layer — 'brew install neovim'" ;;
    claude) print -r -- "Claude Code CLI — https://claude.com/claude-code" ;;
    *)      print -r -- "not found on PATH" ;;
  esac
}

frame_require() {
  # frame_require CMD... — hard-check that each CMD is on PATH. On any miss,
  # print every missing dep with its install hint and exit 127 (the shell's own
  # command-not-found code). All-present is a silent success.
  local _cmd; local -a _missing
  for _cmd in "$@"; do
    command -v "$_cmd" >/dev/null 2>&1 || _missing+=("$_cmd")
  done
  (( $#_missing )) || return 0
  local _noun="dependency"; (( $#_missing > 1 )) && _noun="dependencies"
  print -r -- "$X_MARK frame: missing required $_noun:" >&2
  for _cmd in "${_missing[@]}"; do
    print -r -- "  $X_MARK $_cmd — $(frame_dep_hint "$_cmd")" >&2
  done
  exit 127
}

frame_check_terminal() {
  # Soft, non-blocking. Frame boots in any terminal (it just `exec nvim`s), but
  # the Ghostty-specific window management — `frame focus`, `frame spawn` tabs,
  # click-to-focus on the notify banner — only works when you're in Ghostty.
  # Warn once at boot so it isn't a silent surprise later; never gate on it.
  [[ "${TERM_PROGRAM:-}" == ghostty ]] && return 0
  print -r -- "$WARN_MARK frame: not running in Ghostty (TERM_PROGRAM=${TERM_PROGRAM:-unset}) — frame boots fine here, but focus/spawn window management needs Ghostty" >&2
}

# ── claude-code hooks ─────────────────────────────────────────────────────────

# THE canonical table of claude-code hooks every frame relies on, one row per
# hook: `COMMAND|EVENT|WHY`. Everything reads from here so nothing can drift —
# frame_claude_required_hooks maps the COMMAND column (init's drift check,
# shell's auto-refresh, wt's boot sniff all go through it); init's missing-hooks
# warning maps EVENT+WHY to label each gap; frame_write_claude_hooks writes
# precisely these COMMANDs. Add a hook in ONE place (a row here) and the drift
# check, the write, and the warning label all pick it up together.
#
#   COMMAND  the exact substring that must appear in .claude/settings.json — the
#            drift key. `frame notify` is also frame's fingerprint (present since
#            day one): its absence means the file is the user's own, not a stale
#            frame file.
#   EVENT    the claude-code hook event the command lives under.
#   WHY      the one-line reason, shown when init reports the hook missing.
#
# `frame reload-editor` (PostToolUse) is listed so a frame predating it reads as
# drifted — init --force / shell re-sync then propagate the hook into existing
# frame projects. It's a pure enhancement at runtime (without it, nvim's own
# autoread and a manual :e still work), but it IS part of the canonical wiring,
# so drift detection tracks it. Keep this table in step with
# frame_write_claude_hooks.
frame_claude_hooks_table() {
  print -rl -- \
    'frame notify|Stop|banner + "waiting" status' \
    'frame reply|Stop|route the reply to a requester' \
    'frame status --prompt|UserPromptSubmit|"working" status + turn stamp' \
    'frame notify --blocked|Notification|banner + "blocked" status when claude needs input' \
    'frame swarm --context|SessionStart|injects frame-awareness context at session start' \
    "frame reload-editor|PostToolUse|enables immediate nvim buffer reload on Claude's edits"
}

# frame_claude_required_hooks — the COMMAND column of the table above, one per
# line. The command-substring list init/shell/wt/tests have always consumed;
# now derived from the table so it can never fall out of step with the labels.
frame_claude_required_hooks() {
  local _row
  frame_claude_hooks_table | while IFS= read -r _row; do print -r -- "${_row%%|*}"; done
}

# frame_claude_hooks_missing FILE — print (one per line) the required hooks that
# FILE lacks; nothing when all are present or FILE is absent (grep -qF on a
# missing file just reports every hook missing). Substring match on the command
# string, the same test init/shell have always used. Callers capture with
#   _missing=(${(f)"$(frame_claude_hooks_missing .claude/settings.json)"})
# — unquoted, so zsh drops the lone empty element when nothing is missing.
frame_claude_hooks_missing() {
  local _f=$1 _h
  frame_claude_required_hooks | while IFS= read -r _h; do
    grep -qF "$_h" "$_f" 2>/dev/null || print -r -- "$_h"
  done
}

frame_settings_is_frame_only() {
  # Classify .claude/settings.json (path $1) for a `frame init --force`
  # overwrite. Prints one word:
  #   safe   — empty, or nothing but frame's own hooks; a rewrite loses nothing
  #   custom — foreign hooks, non-frame hook events, or any top-level key besides
  #            "hooks"; a rewrite would clobber the user's content
  #   nojq   — jq isn't installed, so we can't prove the file is safe
  # Proving "there's nothing here but frame's hooks" is a JSON-structure
  # question, not a text one — grep can't tell a frame hook from a lookalike or
  # notice an unknown top-level key a future claude-code adds — so we lean on jq
  # and refuse (classify custom) rather than guess when it can't parse the file.
  local _f=$1
  command -v jq >/dev/null 2>&1 || { print -r -- nojq; return; }
  jq -re '
    def frame_ok:
      (keys - ["hooks"] | length == 0)
      and ((.hooks // {}) | keys - ["Stop","UserPromptSubmit","Notification","SessionStart","PostToolUse"] | length == 0)
      and ([(.hooks // {}) | to_entries[] | .value[]? | .hooks[]? | .command | select(. != null)]
            | all(startswith("frame ")));
    if frame_ok then "safe" else "custom" end
  ' "$_f" 2>/dev/null || print -r -- custom
}

frame_write_claude_hooks() {
  # .claude/settings.json in cwd, wiring claude-code to frame's notification
  # channels: Stop → `frame notify` (banner + "- waiting" title status) and
  # `frame reply` (routes the turn's last message to anyone who req'd this
  # frame); UserPromptSubmit → `frame status --prompt` ("- working" + the
  # turn-start stamp); Notification → `frame notify --blocked` ("- blocked"
  # status + banner) for when claude pauses MID-turn on a permission prompt (or
  # any input) — the one state Stop/UserPromptSubmit structurally can't see, so
  # without it a blocked frame reads as "working" forever. Working/waiting/blocked
  # between them put claude's lifecycle in the window title and `frame ls`.
  # SessionStart → `frame swarm --context`, which injects the frame-awareness
  # block iff the `frame swarm` level is ≥1 (and we're in a frame) — wired
  # unconditionally here; the dial, not this file, decides what it emits.
  # PostToolUse (Edit|Write|MultiEdit|NotebookEdit) → `frame reload-editor`, which
  # reloads the just-edited file into this frame's nvim buffer if it's open and
  # clean, so a buffer-tied viewer (markdown-preview) follows Claude's edits with
  # zero manual action. A pure enhancement: a no-op outside a frame, and nvim's
  # own autoread (or a manual :e) still works if the RPC hook is absent or fails.
  # `frame reply` and `frame reload-editor` both read the hook JSON on stdin
  # (transcript path / edited file_path) — the redirects touch stdout/stderr
  # only, so stdin still flows. Callers guard the file-exists case — this always
  # writes.
  mkdir -p .claude
  cat > .claude/settings.json <<'EOF'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "frame notify >/dev/null 2>&1 || true"
          },
          {
            "type": "command",
            "command": "frame reply >/dev/null 2>&1 || true"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "frame status --prompt >/dev/null 2>&1 || true"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "frame notify --blocked >/dev/null 2>&1 || true"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "frame swarm --context 2>/dev/null || true"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "frame reload-editor >/dev/null 2>&1 || true"
          }
        ]
      }
    ]
  }
}
EOF
}

# ── window titling ────────────────────────────────────────────────────────────

frame_base_title() {
  # frame_base_title NAME TOPIC [PORT] — the bracketed window-title base:
  #   NAME [ TOPIC ]          shell frames, and any pre-nvim title (no port yet)
  #   NAME [ TOPIC :PORT ]    vite worktrees, once the port is known
  # Name stays bare so it reads as an owner; the topic (the thing you tell
  # frames apart by) is wrapped, with the browser's vite port beside it. The
  # mutable " - STATUS" suffix is appended elsewhere — this is only the base.
  # layouts/session.lua rebuilds the same shape in Lua (it owns the title once
  # nvim starts); keep the two in step.
  local _name=$1 _topic=$2 _port=${3:-}
  if [[ -n "$_port" ]]; then
    print -r -- "$_name [ $_topic :$_port ]"
  else
    print -r -- "$_name [ $_topic ]"
  fi
}

set_title() {
  # Set the ghostty window title now, before nvim takes over — windows are
  # Raycast-findable even mid-boot or after nvim exits. Pass a frame_base_title.
  printf '\e]2;%s\e\\' "$1"
}

frame_record_gtab() {
  # frame_record_gtab NAME TOPIC — record this frame's ghostty window+tab id to
  # $FRAME_RUNDIR/NAME-TOPIC.nvim.gtab so `frame focus` (and the notify click)
  # can raise the exact window by id. That id path in commands/focus.sh needs
  # only Automation (tell Ghostty) — NOT System Events / the Accessibility grant,
  # which the notifier app's relaunched click callback can't get (ad-hoc signed,
  # so macOS won't honor its assistive-access grant). Hand-booted frames
  # (frame shell / frame wt exec nvim in the CURRENT window) otherwise have no
  # recording and fall to focus's title matcher — exactly the path that dies with
  # osascript-not-allowed-assistive-access (-1728) from a banner click.
  #
  # spawn writes its OWN authoritative gtab from the window it creates and sets
  # FRAME_SPAWNED=1 so this no-ops: a spawned worker's tab isn't frontmost at
  # boot, so "front window" here would capture the HEAD window's ids and send
  # focus to the wrong window.
  #
  # Best-effort and Ghostty-only: it runs in the terminal the human invoked, so
  # the frame's window is frontmost; if this isn't Ghostty, Automation is denied,
  # or Ghostty predates the AppleScript dictionary, it writes nothing and focus
  # falls back to the matcher. Same "WINDOW_ID TAB_ID" shape frame_open_window
  # and spawn write, and commands/focus.sh reads.
  [[ -n "${FRAME_SPAWNED:-}" ]] && return 0
  [[ "${TERM_PROGRAM:-}" == ghostty ]] || return 0
  local _name=$1 _topic=$2 _ids
  _ids=$(osascript 2>/dev/null <<'APPLESCRIPT'
tell application "Ghostty"
  set w to front window
  set tb to selected tab of w
  return (id of w) & " " & (id of tb)
end tell
APPLESCRIPT
  ) || return 0
  [[ -n "$_ids" ]] && print -r -- "$_ids" > "$FRAME_RUNDIR/$_name-$_topic.nvim.gtab"
  return 0
}

# ── shell topics ──────────────────────────────────────────────────────────────

frame_mint_shell_topic() {
  # Mint a fresh dated scratch topic (2026-07-30-a3f9) that collides with no
  # existing dir under $FRAME_SHELL_HOME (default ~/frames), and print it. Used
  # by `frame shell` and `frame spawn shell` when no TOPIC is given, so a bare
  # invocation always lands somewhere new instead of reusing someone else's
  # scratch. Keep the two callers routed through here so the format can't drift.
  local _home="${FRAME_SHELL_HOME:-$HOME/frames}" _topic
  _topic="$(date +%Y-%m-%d)-$(printf '%04x' $RANDOM)"
  while [[ -d "$_home/$_topic" ]]; do
    _topic="$(date +%Y-%m-%d)-$(printf '%04x' $RANDOM)"
  done
  print -r -- "$_topic"
}

# ── window spawning ───────────────────────────────────────────────────────────

frame_guard_nested() {
  # frame shell / frame wt end in `exec nvim` — run from a terminal buffer of
  # an existing frame's nvim ($NVIM set), that nests a frame INSIDE this one:
  # same window, child process (it dies with its host), and a keyboard that's
  # ambiguous about which nvim your ex-commands reach. Almost always the
  # caller wanted `frame spawn`. Interactive: confirm. Non-interactive (an
  # agent or script inside the frame): refuse outright — a prompt would hang.
  [[ -n "${NVIM:-}" ]] || return 0
  if [[ ! -t 0 ]]; then
    echo "$X_MARK refusing to boot a frame inside this frame's nvim —" >&2
    echo "  use \`frame spawn\`, or run this in a fresh terminal window" >&2
    return 1
  fi
  local _reply
  print -n "you are about to open a NESTED instance of a Frame — it lives inside this frame's window and dies with it (\`frame spawn\` gives it its own). Continue? (y/N) "
  read -r _reply || _reply=""
  [[ "$_reply" == [yY]* ]] && return 0
  echo "$X_MARK aborted — try \`frame spawn\`, or a fresh terminal window" >&2
  return 1
}

frame_open_window() {
  # frame_open_window CMD — open a worker surface running CMD (a zsh -ic
  # command string), without replacing the caller's window. Ghostty ≥1.3 has an
  # AppleScript dictionary, so workers open as TABS congregating in one shared
  # "workers window" inside the running Ghostty — head keeps its own window,
  # workers stack beside it. $FRAME_WORKERS_WINDOW (default
  # $FRAME_RUNDIR/workers.window) remembers "WINDOW_ID TAB_ID" of the last spawn;
  # reuse requires that exact PAIR to still exist. The pair, not the window id
  # alone: Ghostty ids are address-based and get recycled, and a bare window
  # id once resolved to the user's HEAD window after a restart — workers piled
  # in as tabs. A stale/invalid pair falls into the fresh `new window` branch,
  # which re-records. Prints "WINDOW_ID TAB_ID" — callers record it for
  # focus/reap (spawn.sh writes the .gtab). Scripted surfaces do NOT auto-close when CMD
  # exits (they hold on [Process exited] even with wait after command:false —
  # verified against 1.3.1), so callers must arrange an explicit close
  # (`frame spawn close-tab`).
  #
  # Fallback when the dictionary is missing (Ghostty <1.3, script error):
  # legacy separate app instance via `open -na` + `-e`, printing no ids —
  # --quit-after-last-window-closed makes that instance exit with its window.
  # Ghostty's launch hook; callers stay terminal-agnostic above this line.
  local state="${FRAME_WORKERS_WINDOW:-$FRAME_RUNDIR/workers.window}"
  local prev_wid="" prev_tid="" ids=""
  [[ -f "$state" ]] && read -r prev_wid prev_tid < "$state"
  ids=$(osascript - "$prev_wid" "$prev_tid" "/bin/zsh -ic ${(qq)1}" 2>/dev/null <<'APPLESCRIPT'
on run argv
  set wid to item 1 of argv
  set tid to item 2 of argv
  set cmd to item 3 of argv
  tell application "Ghostty"
    set cfg to {command:cmd, wait after command:false}
    if wid is not "" and tid is not "" then
      try
        if (exists tab id tid of window id wid) then
          set w to window id wid
          set tb to new tab in w with configuration cfg
          return (id of w) & " " & (id of tb)
        end if
      end try
    end if
    set w to new window with configuration cfg
    set tb to selected tab of w
    return (id of w) & " " & (id of tb)
  end tell
end run
APPLESCRIPT
  ) || ids=""
  if [[ -n "$ids" ]]; then
    print -r -- "$ids" > "$state"
    print -r -- "$ids"
    return 0
  fi
  open -na Ghostty.app --args --quit-after-last-window-closed=true \
    -e zsh -ic "$1"
}

# ── live-frame discovery ──────────────────────────────────────────────────────

frame_rpc_expr() {
  # frame_rpc_expr SOCKET EXPR [TIMEOUT_S] — evaluate EXPR on the frame at
  # SOCKET over --remote-expr, printing its result on stdout. Returns non-zero
  # on RPC error OR if the session doesn't answer within TIMEOUT_S seconds
  # (default 2, overridable with $FRAME_RPC_TIMEOUT).
  #
  # The timeout is the whole point. A dead socket (no listener) refuses fast
  # and is skipped; a healthy session answers fast. But an nvim that is
  # alive-but-unresponsive — mid-boot, wedged, momentarily not servicing RPC —
  # makes a bare --remote-expr block *forever*. frame_live_frames loops over
  # every $FRAME_RUNDIR/*.nvim, so one such socket would hang `frame ls` and the
  # wt/shell topic-collision guard until Ctrl-C. Bounding each probe means a
  # wedged frame costs at most TIMEOUT_S and is skipped like any dead debris.
  #
  # macOS ships no timeout(1), so we use gtimeout (coreutils) when it's present
  # and otherwise fall back to a dependency-free zsh timer: background the
  # headless client, poll for it, and kill it if it outlives the deadline.
  # --headless is kept on both paths — it stops a piped-stdout nvim from
  # routing the expr result to /dev/tty and probing the terminal (see
  # commands/status.sh for the full story).
  local _sock=$1 _expr=$2 _t=${3:-${FRAME_RPC_TIMEOUT:-2}}
  if (( $+commands[gtimeout] )); then
    gtimeout "$_t" nvim --headless --server "$_sock" --remote-expr "$_expr" 2>/dev/null
    return $?
  fi
  local _out _pid _i _rc
  _out=$(mktemp) || return 1
  nvim --headless --server "$_sock" --remote-expr "$_expr" >"$_out" 2>/dev/null & _pid=$!
  for (( _i = 0; _i < _t * 10; _i++ )); do
    kill -0 $_pid 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 $_pid 2>/dev/null; then          # still running past the deadline
    kill $_pid 2>/dev/null
    wait $_pid 2>/dev/null
    rm -f "$_out"
    return 1
  fi
  wait $_pid; _rc=$?
  (( _rc == 0 )) && cat "$_out"
  rm -f "$_out"
  return $_rc
}

frame_dir_in_use() {
  # frame_dir_in_use DIR — print `pid command` for every live process whose
  # working directory is at or under DIR, one per line; no output means nothing
  # holds it. Teardown consults this before it deletes a worktree: the socket
  # handshake can miss a still-live session (its socket at a legacy path after
  # the rundir move, a wedged nvim that won't answer, a stray terminal left
  # cd'd inside), and removing the tree under a live process orphans the editor
  # and strands its cwd — the husk-directory failure this exists to prevent.
  #
  # lsof is macOS-native; `-d cwd -a +D` selects only the cwd fd of processes
  # rooted under DIR, so the tree walk skips every open data file, and a
  # worktree's node_modules is a symlink lsof won't descend — the probe stays
  # cheap. lsof exits non-zero when nothing matches (the common case), which is
  # simply empty output here. No lsof at all → empty (can't tell); the caller's
  # -f still forces through, so this is never a hard dependency.
  (( $+commands[lsof] )) || return 0
  local _dir=$1 _line _pid=""
  lsof -w -n -P -a -d cwd -F pc +D "$_dir" 2>/dev/null | while IFS= read -r _line; do
    case $_line in
      p*) _pid=${_line#p} ;;
      c*) [[ -n $_pid ]] && print -r -- "$_pid ${_line#c}"; _pid="" ;;
    esac
  done
  return 0
}

frame_live_frames() {
  # Print one `name<TAB>topic<TAB>port<TAB>status` row per running frame on this
  # machine, unsorted. A running frame is exactly one with a live nvim socket at
  # $FRAME_RUNDIR/<name>-<topic>.nvim that answers FrameInfo() over that socket — we ask
  # the session for its own identity rather than parsing the ambiguous
  # <name>-<topic> filename (topics can contain dashes). Sockets that don't
  # answer are skipped: dead debris from a crash, a session predating FrameInfo
  # (a reboot fixes it), or one that's alive but wedged and can't service RPC.
  # frame_rpc_expr bounds each per-socket query with a short timeout, so a
  # single unresponsive frame can't hang the sweep — and thus can't hang
  # `frame ls` or the wt/shell topic-collision guard that call this. Shared by
  # `frame ls` (renders the rows) and the creation paths (topic-collision guard).
  #
  # (N) = null_glob for this one pattern, so an empty rundir expands to nothing
  # rather than the literal. Port/status/health are printed raw ('' when absent);
  # callers render the empty case however they like. `health` is FrameInfo's
  # appended 5th field (broker signal for ls's COMMS column); sessions predating
  # it return only 4 fields, so we peel status off as a bounded field and default
  # health to '' when no 5th field is present — never re-emitting status as
  # health (a bare ${_rec#*sep} returns the string unchanged when sep is absent).
  local _sock _rec _name _topic _port _status _health
  for _sock in $FRAME_RUNDIR/*.nvim(N); do
    [[ -S "$_sock" ]] || continue
    _rec=$(frame_rpc_expr "$_sock" 'v:lua.FrameInfo()') || continue
    [[ -n "$_rec" ]] || continue
    _name=${_rec%%$'\t'*};  _rec=${_rec#*$'\t'}
    _topic=${_rec%%$'\t'*}; _rec=${_rec#*$'\t'}
    _port=${_rec%%$'\t'*};  _rec=${_rec#*$'\t'}
    if [[ "$_rec" == *$'\t'* ]]; then   # 5-field (with health) vs. legacy 4-field
      _status=${_rec%%$'\t'*}; _health=${_rec#*$'\t'}
    else
      _status=$_rec; _health=''
    fi
    [[ -n "$_name" ]] || continue
    print -r -- "$_name	$_topic	$_port	$_status	$_health"
  done
}

frame_resolve_target() {
  # frame_resolve_target SPEC — resolve a `frame req` / `frame deliver` target to
  # a live session, setting NAME / TOPIC / SOCKET. An explicit NAME/TOPIC resolves
  # directly. A bare TOPIC tries the caller's own project first (SELF_NAME/TOPIC —
  # the same-project sibling shortcut), then falls back to the unique LIVE frame
  # carrying that topic, so a head frame (say shell/headv2) reaches `comms2`
  # without naming its project. The fallback's identity comes from FrameInfo
  # (frame_live_frames), never the dash-ambiguous filename. More than one match
  # refuses and lists them; none → not found. Prints the reason and returns 1 on
  # failure. SELF_NAME (set by frame_self_identity) enables the sibling shortcut;
  # unset just falls straight through to the search.
  local spec="$1"
  if [[ "$spec" == */* ]]; then
    NAME="${spec%%/*}" TOPIC="${spec#*/}"
    SOCKET="$FRAME_RUNDIR/$NAME-$TOPIC.nvim"
    if [[ ! -S "$SOCKET" ]]; then
      echo "$X_MARK no frame session for $NAME/$TOPIC (no socket at $SOCKET)" >&2
      return 1
    fi
    return 0
  fi

  TOPIC="$spec"
  # 1. Same-project sibling — our own NAME. Cheap, unambiguous, matches the
  #    historical bare-topic behavior.
  if [[ -n "${SELF_NAME:-}" && -S "$FRAME_RUNDIR/$SELF_NAME-$TOPIC.nvim" ]]; then
    NAME=$SELF_NAME SOCKET="$FRAME_RUNDIR/$SELF_NAME-$TOPIC.nvim"
    return 0
  fi

  # 2. The unique live frame with this topic, across projects.
  local -a hits
  local _n _t _rest
  while IFS=$'\t' read -r _n _t _rest; do
    if [[ "$_t" == "$TOPIC" ]]; then hits+=("$_n"); fi
  done < <(frame_live_frames)

  if (( ${#hits} == 1 )); then
    NAME="${hits[1]}" SOCKET="$FRAME_RUNDIR/${hits[1]}-$TOPIC.nvim"
    return 0
  fi
  if (( ${#hits} > 1 )); then
    echo "$X_MARK ambiguous topic '$TOPIC' — it names ${#hits} live frames; use NAME/TOPIC:" >&2
    local _h
    for _h in $hits; do echo "    $_h/$TOPIC" >&2; done
    return 1
  fi
  echo "$X_MARK no live frame with topic '$TOPIC' — pass NAME/TOPIC to be explicit" >&2
  return 1
}

frame_assert_topic_free() {
  # frame_assert_topic_free NAME TOPIC — refuse (return 1, message on stderr) if
  # any OTHER live frame already carries TOPIC. Topics are the handle
  # `frame focus TOPIC` resolves by, and that match ignores the owner name
  # (see commands/focus.sh), so a topic shared by two live frames is ambiguous:
  # focus silently raises whichever the window server lists first. Enforcing
  # uniqueness at boot keeps that situation from ever existing. A live frame
  # that is this very frame — same NAME and TOPIC, i.e. a reboot/reuse — is fine.
  local _name=$1 _topic=$2 _o_name _o_topic
  while IFS=$'\t' read -r _o_name _o_topic _; do
    [[ "$_o_topic" == "$_topic" ]] || continue
    [[ "$_o_name" == "$_name" ]] && continue   # same frame rebooting — allowed
    echo "$X_MARK topic '$_topic' is already live ($_o_name [ $_o_topic ]) —" >&2
    echo "  topics must be unique so 'frame focus $_topic' is unambiguous." >&2
    echo "  pick another topic, or tear that frame down first: frame wt -d" >&2
    return 1
  done < <(frame_live_frames)
  return 0
}

# ── docker / shared services ──────────────────────────────────────────────────

ensure_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "$RUN_MARK starting OrbStack…"
    open -a OrbStack
    until docker info >/dev/null 2>&1; do sleep 0.5; done
  fi
}

frame_services_up() {
  # frame_services_up [postgres] [minio] — start (default: both) and wait ready.
  ensure_docker
  if (( $# == 0 )); then set -- postgres minio; fi
  echo "$RUN_MARK starting shared services: $*…"
  if ! docker compose -f "$FRAME_SERVICES_COMPOSE" up -d "$@"; then
    echo "$X_MARK frame services failed to start. If a port is taken, an old" >&2
    echo "  per-project stack may still be running (its minio binds :9000):" >&2
    docker ps --format '  {{.Names}}  {{.Ports}}' | grep -E '5432|9000|9001' >&2 || true
    return 1
  fi
  local _s
  for _s in "$@"; do
    case "$_s" in
      postgres) wait_for_pg ;;
      minio)    wait_for_url http://localhost:9000/minio/health/live minio ;;
    esac
  done
}

wait_for_pg() {
  echo "$RUN_MARK waiting for postgres…"
  until docker compose -f "$FRAME_SERVICES_COMPOSE" exec -T postgres \
        pg_isready -U frame -d frame >/dev/null 2>&1; do
    sleep 0.5
  done
  echo "$OK_MARK postgres ready"
}

wait_for_url() {
  # wait_for_url URL [LABEL]
  local _url=$1 _label=${2:-$1}
  echo "$RUN_MARK waiting for $_label…"
  until curl -sf "$_url" >/dev/null 2>&1; do sleep 0.5; done
  echo "$OK_MARK $_label ready"
}

ensure_pg_db() {
  # ensure_pg_db NAME [PASSWORD] — idempotent role + database, owned by the
  # role, on the shared postgres. Role-per-project keeps one project's tests
  # from touching another's database.
  local _db=$1 _pass=${2:-devpassword}
  local -a _psql
  _psql=(docker compose -f "$FRAME_SERVICES_COMPOSE" exec -T postgres
         psql -U frame -d frame -v ON_ERROR_STOP=1 -qAt)
  if [[ "$("${_psql[@]}" -c "SELECT 1 FROM pg_roles WHERE rolname='$_db'")" != 1 ]]; then
    "${_psql[@]}" -c "CREATE ROLE \"$_db\" LOGIN PASSWORD '$_pass'" >/dev/null
    echo "$OK_MARK created role $_db"
  fi
  if [[ "$("${_psql[@]}" -c "SELECT 1 FROM pg_database WHERE datname='$_db'")" != 1 ]]; then
    "${_psql[@]}" -c "CREATE DATABASE \"$_db\" OWNER \"$_db\"" >/dev/null
    echo "$OK_MARK created database $_db"
  fi
}

ensure_minio_bucket() {
  # ensure_minio_bucket BUCKET — idempotent bucket on the shared minio.
  local _b=$1
  docker compose -f "$FRAME_SERVICES_COMPOSE" run --rm mc \
    mb --ignore-existing "local/$_b" >/dev/null 2>&1
  echo "$OK_MARK bucket $_b"
}

# ── misc ──────────────────────────────────────────────────────────────────────

find_free_port() {
  # Scan upward from $1 until a port nothing is listening on.
  local _p=$1
  while lsof -nP -iTCP:$_p -sTCP:LISTEN >/dev/null 2>&1; do
    _p=$((_p + 1))
  done
  echo $_p
}
