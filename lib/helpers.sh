# Frame helper library (zsh). Sourced by bin/frame before any command runs,
# so every function here is also available inside a project's .frame/config.sh
# (stack_up / app_env hooks).

FRAME_SERVICES_COMPOSE="$FRAME_ROOT/services/docker-compose.yml"

# ── status markers ────────────────────────────────────────────────────────────
# Colored only when the stream is a terminal (✗ prints to stderr, ✓/▶ to
# stdout) and NO_COLOR is unset — piped output, logs, and the worktree.lua
# teardown watcher keep seeing the bare characters.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  X_MARK=$'\e[1;31m✗\e[0m'
else
  X_MARK='✗'
fi
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  OK_MARK=$'\e[32m✓\e[0m'
  RUN_MARK=$'\e[36m▶\e[0m'
else
  OK_MARK='✓'
  RUN_MARK='▶'
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

# ── claude-code hooks ─────────────────────────────────────────────────────────

frame_write_claude_hooks() {
  # .claude/settings.json in cwd, wiring claude-code to frame's notification
  # channels: Stop → `frame notify` (banner + "- waiting" title status) and
  # `frame reply` (routes the turn's last message to anyone who req'd this
  # frame); UserPromptSubmit → `frame status --prompt` ("- working" + the
  # turn-start stamp). Working/waiting between them put claude's lifecycle in
  # the window title and `frame ls`. `frame reply` reads the hook JSON on stdin
  # (transcript path) — the redirects touch stdout/stderr only, so stdin still
  # flows. Callers guard the file-exists case — this always writes.
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
  # layouts/worktree.lua rebuilds the same shape in Lua (it owns the title once
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
  # /tmp/frame-workers.window) remembers "WINDOW_ID TAB_ID" of the last spawn;
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
  local state="${FRAME_WORKERS_WINDOW:-/tmp/frame-workers.window}"
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
  # every /tmp/*.nvim, so one such socket would hang `frame ls` and the
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

frame_live_frames() {
  # Print one `name<TAB>topic<TAB>port<TAB>status` row per running frame on this
  # machine, unsorted. A running frame is exactly one with a live nvim socket at
  # /tmp/<name>-<topic>.nvim that answers FrameInfo() over that socket — we ask
  # the session for its own identity rather than parsing the ambiguous
  # <name>-<topic> filename (topics can contain dashes). Sockets that don't
  # answer are skipped: dead debris from a crash, a session predating FrameInfo
  # (a reboot fixes it), or one that's alive but wedged and can't service RPC.
  # frame_rpc_expr bounds each per-socket query with a short timeout, so a
  # single unresponsive frame can't hang the sweep — and thus can't hang
  # `frame ls` or the wt/shell topic-collision guard that call this. Shared by
  # `frame ls` (renders the rows) and the creation paths (topic-collision guard).
  #
  # (N) = null_glob for this one pattern, so an empty /tmp expands to nothing
  # rather than the literal. Port/status are printed raw ('' when absent);
  # callers render the empty case however they like.
  local _sock _rec _name _topic _port _status
  for _sock in /tmp/*.nvim(N); do
    [[ -S "$_sock" ]] || continue
    _rec=$(frame_rpc_expr "$_sock" 'v:lua.FrameInfo()') || continue
    [[ -n "$_rec" ]] || continue
    _name=${_rec%%$'\t'*};  _rec=${_rec#*$'\t'}
    _topic=${_rec%%$'\t'*}; _rec=${_rec#*$'\t'}
    _port=${_rec%%$'\t'*};  _status=${_rec#*$'\t'}
    [[ -n "$_name" ]] || continue
    print -r -- "$_name	$_topic	$_port	$_status"
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
    SOCKET="/tmp/$NAME-$TOPIC.nvim"
    if [[ ! -S "$SOCKET" ]]; then
      echo "$X_MARK no frame session for $NAME/$TOPIC (no socket at $SOCKET)" >&2
      return 1
    fi
    return 0
  fi

  TOPIC="$spec"
  # 1. Same-project sibling — our own NAME. Cheap, unambiguous, matches the
  #    historical bare-topic behavior.
  if [[ -n "${SELF_NAME:-}" && -S "/tmp/$SELF_NAME-$TOPIC.nvim" ]]; then
    NAME=$SELF_NAME SOCKET="/tmp/$SELF_NAME-$TOPIC.nvim"
    return 0
  fi

  # 2. The unique live frame with this topic, across projects.
  local -a hits
  local _n _t _rest
  while IFS=$'\t' read -r _n _t _rest; do
    if [[ "$_t" == "$TOPIC" ]]; then hits+=("$_n"); fi
  done < <(frame_live_frames)

  if (( ${#hits} == 1 )); then
    NAME="${hits[1]}" SOCKET="/tmp/${hits[1]}-$TOPIC.nvim"
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
