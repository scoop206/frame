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
  # A repo rooted at $HOME is a dotfiles repo, never a frame project: without
  # this, any un-git'd dir under ~ (a fresh project before `git init`) resolves
  # to ~ itself, and init scaffolds into — or reports on — the home dir.
  local _top
  _top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ "${_top:A}" == "${HOME:A}" ]] && return 1
  print -r -- "$_top"
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

  # WT_LINKS starts at its default, so a config can replace it (WT_LINKS=(…))
  # or extend it (WT_LINKS+=(…), what init's layers write). See wt.sh.
  WT_LINKS=(.env web/node_modules)

  # Machine-wide base layer: personal hooks (e.g. merge_epilog) shared by every
  # project on this box. Sourced BEFORE the project config so any project can
  # override or unset what it defines.
  frame_source_machine_config

  local _dir _f _cfg=""
  for _dir in "$PROJECT_ROOT" "$MAIN_WT"; do
    for _f in "$_dir/.frame/local/config.sh" "$_dir/.frame/config.sh"; do
      if [[ -f "$_f" ]]; then _cfg=$_f; break 2; fi
    done
  done
  if [[ -n "$_cfg" ]]; then
    source "$_cfg"
  fi

  # NAME defaults to the primary checkout's directory name, so it follows a
  # repo rename — most projects never set it. PORT_PREFIX namespaces the
  # prefixed port exports (e.g. FLIPNEM_VITE_PORT, see wt.sh); the derivation
  # squashes anything not alphanumeric to '_' so a dotted dirname
  # (example.com) still yields a legal env-var prefix, and prepends '_' when
  # the name leads with a digit (4mspecialties.com → _4MSPECIALTIES_COM) since
  # a shell identifier can't start with one. A project whose committed code
  # reads prefixed vars should pin PORT_PREFIX in config.sh — the derived
  # value silently drifts away from the app code on a rename.
  : "${NAME:=${MAIN_WT:t}}"
  : "${PORT_PREFIX:=${(U)NAME//[^[:alnum:]]/_}}"
  if [[ "$PORT_PREFIX" == [0-9]* ]]; then PORT_PREFIX="_$PORT_PREFIX"; fi
}

frame_source_machine_config() {
  # The XDG-standard ~/.config/frame/config.sh — personal hooks and service
  # overrides (FRAME_PG_*/FRAME_MINIO_*) shared by every project on this box.
  # Opt-in and sourced — unlike $FRAME_GLOBAL_CONFIG (key=value, never sourced
  # so hot-path reads execute nothing).
  local _global="${XDG_CONFIG_HOME:-$HOME/.config}/frame/config.sh"
  [[ -f "$_global" ]] && source "$_global"
  return 0
}

frame_self_identity() {
  # Sets SELF_NAME / SELF_TOPIC to THIS frame's own identity — used as a reply
  # return address by `frame agent` (arming) and as the socket to read by
  # `frame reply` / `frame inbox`. Same derivation as status.sh: the session env
  # wins (a shell frame may sit in another project's checkout, where git would
  # name the wrong frame — e.g. a reply address of ulc/master); a bare shell
  # outside any frame derives it from the worktree dir (_NAME-TOPIC) or branch. Returns 1 with SELF_* unset
  # when not inside any frame — the caller decides whether that's fatal.
  if [[ -n "${FRAME_NAME:-}" && -n "${FRAME_TOPIC:-}" ]]; then
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
  frame_kvfile_get "$FRAME_GLOBAL_CONFIG" "$1"
  return 0
}

frame_global_set() {
  # frame_global_set KEY VALUE — update KEY in place (comments, blank lines,
  # and other keys survive) or append it; the first write creates the file.
  frame_kvfile_set "$FRAME_GLOBAL_CONFIG" "$1" "$2" \
    "# frame settings for every project on this machine (key=value)."
}

# ── key=value files ───────────────────────────────────────────────────────────
# The one on-disk format behind both the machine-global switches above and the
# layered `frame kv` settings below: KEY=VALUE lines, # comments and blanks
# allowed, last occurrence wins. Read by pattern match, never sourced.

frame_kvfile_get() {
  # frame_kvfile_get FILE KEY — print KEY's value; return 1 when the file or
  # key is absent (so callers can tell "unset" from "set to empty").
  local -a _hits
  [[ -f "$1" ]] || return 1
  _hits=(${(M)${(@f)"$(<$1)"}:#$2=*})
  (( $#_hits )) || return 1
  print -r -- "${_hits[-1]#*=}"
}

frame_kvfile_set() {
  # frame_kvfile_set FILE KEY VALUE [HEADER] — update KEY in place (comments,
  # blank lines, and other keys survive) or append it. The first write creates
  # the file (and its dir), starting with HEADER when given.
  local _file=$1 _k=$2 _v=$3 _header=${4:-} _i _found=0
  local -a _lines
  mkdir -p "${_file:h}"
  if [[ ! -f "$_file" ]]; then
    if [[ -n "$_header" ]]; then print -r -- "$_header" > "$_file"; else : > "$_file"; fi
  fi
  _lines=("${(@f)$(<$_file)}")
  for (( _i=1; _i <= $#_lines; _i++ )); do
    if [[ "$_lines[_i]" == $_k=* ]]; then
      _lines[_i]="$_k=$_v"
      _found=1
    fi
  done
  (( _found )) || _lines+=("$_k=$_v")
  print -rl -- "${_lines[@]}" > "$_file"
}

frame_kvfile_unset() {
  # frame_kvfile_unset FILE KEY — drop every KEY= line; return 1 if there was
  # none (nothing to unset). Other lines, comments included, survive.
  local -a _lines _kept
  [[ -f "$1" ]] || return 1
  _lines=("${(@f)$(<$1)}")
  _kept=(${_lines:#$2=*})
  (( $#_kept < $#_lines )) || return 1
  print -rl -- "${_kept[@]}" > "$1"
}

# ── frame kv: layered agent-behavior settings ─────────────────────────────────
# Settings that tell a frame's claude how far to carry its work on its own
# (autocommit, merge_on_commit, push_on_merge, deploy_on_merge, spawn_frames —
# the full list, with meanings, is the defaults file), plus any keys a project or
# user declares for itself (below). Four value layers, first hit wins:
#
#   frame    ~/.local/share/frame/kv/<NAME>/<TOPIC>   one frame; reaped by frame wt -d
#   project  <primary checkout>/.frame/local/kv        every frame of one project
#   user     ~/.config/frame/kv                        every project on this machine
#   default  the declared default (see declarations)
#
# Deliberately files, not environment variables: a process's env is frozen at
# its start, so a value exported at boot (or set later in some other buffer)
# never reaches the running claude. Files are read at the moment of use, so a
# change lands mid-session. The project layer lives under the gitignored
# .frame/local/ so setting it never dirties the primary checkout (which would
# block frame merge's clean-tree guard). The frame layer is under $HOME rather
# than $FRAME_RUNDIR because /tmp is reaped after a few idle days.
#
# Declarations — which keys exist, their default, and what they mean — come
# from up to three files in kv.defaults format (a `key=default` line, its
# meaning in the comment block right above it; first comment line = the
# one-line description), read in this order:
#
#   builtin  $FRAME_ROOT/kv.defaults                   shipped with frame
#   project  <primary checkout>/.frame/kv.defaults     committed; the team's keys
#   user     ~/.config/frame/kv.defaults               this machine's own keys
#
# The first declaration of a key wins: a project or user file can't redefine a
# built-in (warned and ignored — change its VALUE in a layer instead), and a
# project declaration beats a user one. A default of true/false makes the key
# boolean (true grants, false restrains); anything else makes it a string.
# Frame itself only stores and advertises custom keys — agents, hooks, and
# scripts read them with `frame kv get`.
#
# Agent notes: any key NOT declared anywhere is the agent's own to set, on its
# own frame only (ticket=ENG-412, blocked_on=…). They live in a file of their
# own beside the frame layer (<TOPIC>.agent, reaped with it by frame wt -d) and
# are only ever consulted for undeclared keys — so a note can never shadow a
# setting, even one declared after the note was written. Lookups report them
# as "frame (agent)".
#
# Callers first pick WHOSE settings to read with frame_kv_scope, then query.

FRAME_KV_DEFAULTS="$FRAME_ROOT/kv.defaults"
FRAME_KV_LAYERS=(frame project user default)
FRAME_KV_DECL_SOURCES=(builtin project user)

frame_kv_scope() {
  # frame_kv_scope NAME TOPIC MAIN_WT — point the kv lookups at one frame. Any
  # argument may be empty: no NAME/TOPIC drops the frame layer, no MAIN_WT the
  # project layer and project declarations (a shell frame has no primary
  # checkout). Loads the declarations for that scope.
  local _name=$1 _topic=$2 _main=$3
  local _cfg="${XDG_CONFIG_HOME:-$HOME/.config}/frame"
  typeset -gA FRAME_KV_FILE FRAME_KV_DECL_FILE
  FRAME_KV_FILE=(
    frame   ""
    project ""
    user    "$_cfg/kv"
    default ""
  )
  FRAME_KV_DECL_FILE=(
    builtin "$FRAME_KV_DEFAULTS"
    project ""
    user    "$_cfg/kv.defaults"
  )
  typeset -g FRAME_KV_AGENT_FILE=""
  if [[ -n "$_name" && -n "$_topic" ]]; then
    # A topic may contain '/' (feature/x) — flatten so it stays one file.
    FRAME_KV_FILE[frame]="$HOME/.local/share/frame/kv/$_name/${_topic//\//%}"
    FRAME_KV_AGENT_FILE="${FRAME_KV_FILE[frame]}.agent"
  fi
  if [[ -n "$_main" ]]; then
    FRAME_KV_FILE[project]="$_main/.frame/local/kv"
    FRAME_KV_DECL_FILE[project]="$_main/.frame/kv.defaults"
  fi
  _frame_kv_load_decls
  return 0
}

_frame_kv_load_decls() {
  # Parse FRAME_KV_DECL_FILE into globals:
  #   FRAME_KV_KEYS          declared keys, in declaration order
  #   FRAME_KV_DEF[k]        default value
  #   FRAME_KV_DESC[k]       comment block, '#' stripped, newline-joined
  #   FRAME_KV_FROM[k]       builtin | project | user
  #   FRAME_KV_WARNINGS      clashes and malformed lines (shown by `frame kv`)
  typeset -ga FRAME_KV_KEYS FRAME_KV_WARNINGS
  typeset -gA FRAME_KV_DEF FRAME_KV_DESC FRAME_KV_FROM
  FRAME_KV_KEYS=() FRAME_KV_WARNINGS=() FRAME_KV_DEF=() FRAME_KV_DESC=() FRAME_KV_FROM=()
  local _src _file _line _k _v _n
  local -a _block
  for _src in $FRAME_KV_DECL_SOURCES; do
    _file=${FRAME_KV_DECL_FILE[$_src]:-}
    [[ -n "$_file" && -f "$_file" ]] || continue
    _block=() _n=0
    for _line in "${(@f)$(<$_file)}"; do
      (( ++_n ))
      if [[ "$_line" == \#* ]]; then
        _line=${_line#\#}; _block+=("${_line# }")
        continue
      fi
      if [[ -z "${_line//[[:space:]]/}" ]]; then
        _block=(); continue
      fi
      _k=${_line%%=*} _v=${_line#*=}
      if [[ "$_line" != *=* ]] || ! frame_kv_valid_key "$_k"; then
        FRAME_KV_WARNINGS+=("$_file:$_n: not a declaration (want key=default, key like my_key) — skipped")
      elif [[ -n "${FRAME_KV_FROM[$_k]:-}" ]]; then
        if [[ "${FRAME_KV_FROM[$_k]}" == builtin ]]; then
          FRAME_KV_WARNINGS+=("$_file:$_n: $_k is a built-in key — declaration ignored (set its value with frame kv set)")
        elif [[ "${FRAME_KV_DEF[$_k]}" != "$_v" ]]; then
          FRAME_KV_WARNINGS+=("$_file:$_n: $_k is already declared by the ${FRAME_KV_FROM[$_k]} (default ${FRAME_KV_DEF[$_k]}) — this one is ignored")
        fi
      else
        FRAME_KV_KEYS+=("$_k")
        FRAME_KV_DEF[$_k]=$_v
        FRAME_KV_DESC[$_k]=${(pj:\n:)_block}
        FRAME_KV_FROM[$_k]=$_src
      fi
      _block=()
    done
  done
  return 0
}

frame_kv_scope_self() {
  # Scope to the frame we're running inside (or, from a bare checkout, to its
  # branch — frame_self_identity's derivation). Never fails: outside any frame
  # it just leaves the user + default layers.
  local _main=""
  if frame_self_identity 2>/dev/null; then
    frame_load_config 2>/dev/null && _main=$MAIN_WT
    frame_kv_scope "$SELF_NAME" "$SELF_TOPIC" "$_main"
  else
    frame_kv_scope "" "" ""
  fi
}

_frame_kv_ensure_scope() {
  # Unscoped callers still see the built-in (and user) declarations.
  (( ${+FRAME_KV_DECL_FILE} )) || frame_kv_scope "" "" ""
}

frame_kv_lookup() {
  # frame_kv_lookup KEY — set KV_VALUE to KEY's effective value and KV_LAYER to
  # the layer it came from; return 1 (both empty) when no layer sets it. A
  # declared default reports as "default", or "default (project|user)" for a
  # custom key; an agent note (undeclared key) as "frame (agent)". Sets
  # globals rather than printing so the caller gets both without a subshell.
  _frame_kv_ensure_scope
  local _layer _file _v
  if ! frame_kv_is_declared "$1"; then
    if [[ -n "$FRAME_KV_AGENT_FILE" ]] && _v=$(frame_kvfile_get "$FRAME_KV_AGENT_FILE" "$1"); then
      KV_VALUE=$_v KV_LAYER="frame (agent)"
      return 0
    fi
    KV_VALUE="" KV_LAYER=""
    return 1
  fi
  for _layer in $FRAME_KV_LAYERS; do
    if [[ "$_layer" == default ]]; then
      (( ${+FRAME_KV_DEF[$1]} )) || continue
      KV_VALUE=${FRAME_KV_DEF[$1]} KV_LAYER=default
      [[ "${FRAME_KV_FROM[$1]}" == builtin ]] || KV_LAYER+=" (${FRAME_KV_FROM[$1]})"
      return 0
    fi
    _file=${FRAME_KV_FILE[$_layer]:-}
    [[ -n "$_file" ]] || continue
    if _v=$(frame_kvfile_get "$_file" "$1"); then
      KV_VALUE=$_v KV_LAYER=$_layer
      return 0
    fi
  done
  KV_VALUE="" KV_LAYER=""
  return 1
}

frame_kv_get() {
  # frame_kv_get KEY — print KEY's effective value (nothing when unset).
  frame_kv_lookup "$1" || return 1
  print -r -- "$KV_VALUE"
}

frame_kv_is_true() {
  # frame_kv_is_true KEY — succeed iff KEY resolves to true (in the current
  # scope). Anything else — false, unset, junk — is false: every boolean
  # setting grants autonomy, so the fail-safe reading is "no".
  [[ "$(frame_kv_get "$1")" == true ]]
}

frame_kv_keys() {
  # Print the declared keys, one per line: built-ins, then project, then user.
  _frame_kv_ensure_scope
  (( $#FRAME_KV_KEYS )) && print -rl -- "${FRAME_KV_KEYS[@]}"
  return 0
}

frame_kv_is_declared() {
  # frame_kv_is_declared KEY — succeed iff some declaration file declares KEY.
  _frame_kv_ensure_scope
  (( ${+FRAME_KV_DEF[$1]} ))
}

frame_kv_valid_key() {
  # frame_kv_valid_key KEY — lowercase letters, digits, _; starts with a letter.
  [[ "$1" == [a-z]* && "$1" != *[^a-z0-9_]* ]]
}

frame_kv_agent_keys() {
  # Print this frame's agent notes, one key per line, in file order. With
  # --shadowed, print instead the notes a declaration now hides (ignored).
  _frame_kv_ensure_scope
  [[ -n "$FRAME_KV_AGENT_FILE" && -f "$FRAME_KV_AGENT_FILE" ]] || return 0
  local _line _k
  for _line in "${(@f)$(<$FRAME_KV_AGENT_FILE)}"; do
    [[ "$_line" == *=* ]] || continue
    _k=${_line%%=*}
    frame_kv_valid_key "$_k" || continue
    if frame_kv_is_declared "$_k"; then
      [[ "${1:-}" == --shadowed ]] && print -r -- "$_k"
    else
      [[ "${1:-}" == --shadowed ]] || print -r -- "$_k"
    fi
  done
  return 0
}

frame_kv_is_bool() {
  # frame_kv_is_bool KEY — succeed iff KEY's declared default is true/false.
  _frame_kv_ensure_scope
  [[ "${FRAME_KV_DEF[$1]:-}" == (true|false) ]]
}

frame_export_claude_flags() {
  # The claude buffer's command (buffers.json) reads ${FRAME_CLAUDE_FLAGS}.
  # The machine's yolo switch (`frame yolo on`) adds
  # --dangerously-skip-permissions to every frame's claude. Called by each
  # boot path (wt.sh, shell.sh) just before exec'ing the layout.
  #
  # Always: --settings FILE, where FILE is a copy of frame's claude/hooks.json
  # (see frame_claude_hooks_file) beside the machine config, in
  # ~/.local/share/frame/ — re-copied whenever frame's version differs, so a hook
  # added to frame reaches every claude on its next boot. The copy, not frame's
  # own file, because the flags are word-split unquoted inside the buffer's
  # `zsh -c "…"`: frame may live at a path with spaces (~/My Tools/frame), a home
  # dir practically never does. If it does, or the copy fails, warn and boot
  # without the hooks.
  local _src=$(frame_claude_hooks_file) _dst="${FRAME_GLOBAL_CONFIG:h}/claude-hooks.json"
  FRAME_CLAUDE_FLAGS=""
  if [[ ! -f "$_src" ]]; then
    echo "$WARN_MARK $_src is missing — claude boots without frame's hooks" >&2
  elif [[ "$_dst" == *[[:space:]\'\"\\]* ]]; then
    echo "$WARN_MARK $_dst has spaces or quotes, so claude can't be pointed at it — booting without frame's hooks" >&2
  elif ! { cmp -s "$_src" "$_dst" || { mkdir -p "${_dst:h}" \
          && cp "$_src" "$_dst.$$" && mv -f "$_dst.$$" "$_dst"; }; }; then
    echo "$WARN_MARK couldn't copy frame's hooks to $_dst — claude boots without them" >&2
  else
    FRAME_CLAUDE_FLAGS="--settings $_dst"
  fi
  if [[ "$(frame_global_get yolo)" == on ]]; then
    FRAME_CLAUDE_FLAGS+="${FRAME_CLAUDE_FLAGS:+ }--dangerously-skip-permissions"
  fi
  export FRAME_CLAUDE_FLAGS
}

frame_session_id_for_dir() {
  # frame_session_id_for_dir DIR — echo the newest claude session id for the
  # worktree DIR, or return 1 if none. This is how `frame wt --from TOPIC`
  # finds a sibling frame's warm session to resume (see commands/wt.sh).
  #
  # Claude Code stores transcripts at
  #   ~/.claude/projects/<sanitized-cwd>/<session-id>.jsonl
  # where <sanitized-cwd> is the frame's absolute cwd with every
  # non-alphanumeric character replaced by '-' (verified against a live
  # session: /Users/x/git_repos/_frame-topic → -Users-x-git-repos--frame-topic).
  # So the id is derivable from the worktree path alone — no cooperation from
  # the source claude, which may still be running or already gone. "Newest"
  # (by mtime) is the frame's active/most-recent session.
  emulate -L zsh
  local _dir="${1:A}"
  local _proj="${_dir//[^A-Za-z0-9]/-}"
  local _pdir="$HOME/.claude/projects/$_proj"
  [[ -d "$_pdir" ]] || return 1
  # (N) nullglob, (.) regular files, (om) newest-first by mtime, [1] the first.
  local _newest=( "$_pdir"/*.jsonl(N.om[1]) )
  (( $#_newest )) || return 1
  print -r -- "${_newest[1]:t:r}"
}

frame_bridge_transcript() {
  # frame_bridge_transcript SESSION_ID DEST_DIR — make SESSION_ID's claude
  # transcript resumable from DEST_DIR. `claude --resume <id>` only looks in the
  # project dir for its OWN cwd (~/.claude/projects/<sanitized-cwd>/), so a
  # session recorded under one worktree can't be resumed from another — it fails
  # "No conversation found" even though the transcript is right there under a
  # different project key. `frame wt --from` (and a cross-project --resume) hit
  # exactly this: they resume a sibling's session into a NEW worktree. Copy the
  # transcript into DEST_DIR's project dir so the resume finds it there. The
  # sanitize rule matches frame_session_id_for_dir (every non-alnum char → '-',
  # verified against live sessions). Best-effort: return 1 if the source
  # transcript can't be located, so the caller can warn rather than boot into a
  # dead --resume; a no-op success when it already lives in DEST_DIR's project
  # (a same-path reboot), which also makes re-runs idempotent.
  emulate -L zsh
  local _id=$1 _dest="${2:A}"
  local _projects="$HOME/.claude/projects"
  local _src=( "$_projects"/*/"$_id".jsonl(N.om[1]) )
  (( $#_src )) || return 1
  local _dest_slug="${_dest//[^A-Za-z0-9]/-}"
  [[ "${_src[1]:h:t}" == "$_dest_slug" ]] && return 0    # already resumable here
  mkdir -p "$_projects/$_dest_slug" \
    && cp -f "${_src[1]}" "$_projects/$_dest_slug/$_id.jsonl"
}

frame_session_transcript() {
  # frame_session_transcript SESSION_ID — echo the path of SESSION_ID's
  # transcript (the newest copy, when frame_bridge_transcript has copied it into
  # several project dirs), or return 1 if there is none.
  emulate -L zsh
  local _f=( "$HOME/.claude/projects"/*/"$1".jsonl(N.om[1]) )
  (( $#_f )) || return 1
  print -r -- "$_f[1]"
}

frame_session_cwd() {
  # frame_session_cwd TRANSCRIPT — echo the cwd the session last ran in, from
  # the newest "cwd" field in the transcript. `claude --resume` only finds a
  # session from that dir's project key. The LAST cwd, not the first: a session
  # bridged into a new worktree and resumed there now lives in the new dir.
  # Only the file's tail is read; transcripts run to tens of MB.
  emulate -L zsh
  local _cwd
  _cwd=$(tail -n 200 "$1" | LC_ALL=C grep -F '"cwd":' \
    | jq -r 'select(type == "object") | .cwd // empty' 2>/dev/null | tail -n 1)
  [[ -n "$_cwd" ]] || return 1
  print -r -- "$_cwd"
}

frame_session_preview() {
  # frame_session_preview TRANSCRIPT — print what the user typed in a session,
  # newest last, for the `frame shell --find` picker's preview pane. Same
  # filters as frame_session_search: typed messages only.
  emulate -L zsh
  [[ -f "$1" ]] || return 1
  print -r -- "session ${1:t:r}"
  local _cwd
  _cwd=$(frame_session_cwd "$1") || _cwd='?'
  print -r -- "cwd     ${_cwd/#$HOME/~}"
  print
  perl -ne '
      next unless index($_, q{"type":"user"}) >= 0;
      next if index($_, q{"type":"tool_result"}) >= 0;
      s/"data":"[^"]{200,}"/"data":""/g; print;' -- "$1" \
    | jq -R -r '
        fromjson? // empty
        | select(type == "object" and .type == "user" and .isMeta != true
                 and .isSidechain != true and .isCompactSummary != true)
        | (.message.content
           | if type == "string" then .
             else [.[]? | select(.type? == "text") | .text] | join("\n") end) as $t
        | select($t != "")
        | select($t | test("^\\s*(<(command-|local-command|system-reminder|task-notification|bash-|user-prompt)|Caveat:)") | not)
        | ((.timestamp // "") | (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M"))? // .[0:16]) as $when
        | "\($when)  \($t[0:600] | gsub("[\\s]+"; " "))\n"' \
    | tail -n 80
}

frame_session_pick() {
  # frame_session_pick ROWS — let the user choose one of frame_session_search's
  # rows; echo its session id. fzf (with a preview of what was typed in the
  # session) when it's installed, else a numbered list read from the tty.
  # With no tty to ask on, print the list and how to resume one, and return 1.
  # The UI goes to stderr / the tty; stdout carries only the id.
  emulate -L zsh
  zmodload -F zsh/datetime b:strftime
  local _rows=$1 _mt _id _cwd _f _snip _when _where _i _mark _k _v
  local -a _ids _lines _menu
  # ● marks a session that's open right now (picking it switches to it).
  local -A _running
  while IFS=$'\t' read -r _k _v; do _running[$_k]=$_v; done < <(frame_session_running)
  while IFS=$'\t' read -r _mt _id _cwd _f _snip; do
    [[ -n "$_id" ]] || continue
    strftime -s _when '%Y-%m-%d %H:%M' "$_mt"
    _where=${_cwd/#$HOME/\~}
    [[ -n "${_running[$_id]:-}" ]] && _mark='● ' || _mark='  '
    _ids+=("$_id")
    _lines+=("$_mark$_when  $_where  $_snip")
    _menu+=("$_id"$'\t'"$_f"$'\t'"$_mark$_when  $_where  $_snip")
  done <<< "$_rows"
  (( $#_ids )) || return 1

  if [[ -t 2 ]] && { : < /dev/tty; } 2>/dev/null; then
    if (( $+commands[fzf] )); then
      local _pick _preview
      _preview="zsh -fc 'source \"\$1\"/lib/helpers.sh && frame_session_preview \"\$2\"' _ ${(q)FRAME_ROOT} {2}"
      _pick=$(print -rl -- "${_menu[@]}" | fzf --delimiter=$'\t' --with-nth=3 \
        --no-sort --no-multi --layout=reverse --height=80% \
        --prompt='resume> ' --header='pick a session to resume (● = open now: switches to it; esc to cancel)' \
        --preview="$_preview" --preview-window='down,50%,wrap' \
        2>/dev/tty) || return 1
      # No `</dev/tty` on fzf: it opens the tty for keys itself, and in zsh
      # (MULTIOS) `pipe | fzf </dev/tty` feeds fzf the pipe AND the tty —
      # the list never ends and a helper eats keystrokes, so fzf hangs blank.
      print -r -- "${_pick%%$'\t'*}"
      return 0
    fi
    local _n=$(( $#_ids < 20 ? $#_ids : 20 )) _ans
    for _i in {1..$_n}; do
      print -r -- "  $_i) ${_lines[_i][1,150]}" >&2
    done
    (( $#_ids > _n )) && print -r -- "  … $(( $#_ids - _n )) older — narrow the search to see them" >&2
    print -n -- "resume which? [1-$_n, enter to cancel] " >&2
    read -r _ans < /dev/tty || return 1
    [[ "$_ans" == <1-> ]] && (( _ans <= _n )) || return 1
    print -r -- "$_ids[_ans]"
    return 0
  fi

  for _i in {1..$(( $#_ids < 20 ? $#_ids : 20 ))}; do
    print -r -- "  $_ids[_i]  ${_lines[_i][1,130]}" >&2
  done
  print -r -- "no tty to pick on — rerun with --resume ID" >&2
  return 1
}

frame_session_search() {
  # frame_session_search WORD… — find past claude sessions whose human-typed
  # messages contain every WORD (case-insensitive, any order, across the
  # session's messages). Only what the user typed counts: tool results,
  # assistant text, hook/command echoes and subagent sidechains are skipped,
  # so "tax" doesn't hit every transcript that mentions "syntax".
  #
  # Prints one tab-separated row per session, newest activity first:
  #   EPOCH  SESSION_ID  CWD  TRANSCRIPT  SNIPPET
  # SNIPPET is the newest message matching the most words, on one line; CWD is
  # where that message was typed (frame_session_cwd gives the session's latest).
  # Returns 1 when nothing matches.
  #
  # Speed: ~/.claude/projects runs to GBs. One perl pass (fast and everywhere;
  # BSD grep -i is ~10x slower) keeps only user lines that hold some word,
  # drops tool results, and blanks base64 image payloads, so jq only parses
  # a few MB.
  emulate -L zsh
  setopt pipefail extendedglob
  (( $# )) || return 1
  local -a _files _pre _words
  _files=( "$HOME/.claude/projects"/*/*.jsonl(N.) )
  (( $#_files )) || return 1
  local _w
  for _w in "$@"; do
    _words+=("${(L)_w}")
    # A word JSON would escape (quotes, backslashes, non-ASCII) can't be
    # matched in the raw line; leave it to jq.
    [[ "$_w" == [[:print:]]## && "$_w" != *[\"\\]* ]] && _pre+=("${(L)_w}")
  done

  local _hits
  _hits=$(FRAME_SEARCH_PRE="${(pj:\n:)_pre}" perl -ne '
      BEGIN { @w = grep { length } split /\n/, ($ENV{FRAME_SEARCH_PRE} // "") }
      next unless index($_, q{"type":"user"}) >= 0;
      next if index($_, q{"type":"tool_result"}) >= 0;
      if (@w) { my $l = lc $_; next unless grep { index($l, $_) >= 0 } @w }
      s/"data":"[^"]{200,}"/"data":""/g;
      print "$ARGV:$_";' -- "${_files[@]}" \
    | jq -R -r --args '
        $ARGS.positional as $words
        | ($ARGS.positional | map(gsub("(?<c>[\\\\^$.|?*+()\\[\\]{}])"; "\\\(.c)"))) as $res
        | capture("^(?<f>[^:]*\\.jsonl):(?<j>.*)$")? | . as $l
        | ($l.j | fromjson?) // empty
        | select(type == "object" and .type == "user"
                 and .isMeta != true and .isSidechain != true
                 and .isCompactSummary != true
                 and .entrypoint != "sdk-cli")
        | (.message.content
           | if type == "string" then .
             else [.[]? | select(.type? == "text") | .text] | join("\n") end) as $t
        | select($t != "")
        | select($t | test("^\\s*(<(command-|local-command|system-reminder|task-notification|bash-|user-prompt)|Caveat:)") | not)
        | ($t | ascii_downcase) as $lt
        # A word matches at a word start: "tax" finds "taxes", not "syntax".
        | [range($res | length) | select(. as $i | ($lt | contains($words[$i]))
                                            and ($lt | test("(^|[^[:alnum:]])" + $res[$i])))] as $hit
        | select($hit | length > 0)
        # No empty fields: IFS=tab read would merge the tabs around one.
        | [$l.f, (.timestamp // "-"), (.cwd // "?"), ($hit | map(tostring) | join(",")),
           # Snippet: the text around the first hit, so a long paste shows
           # why it matched rather than its first line.
           ((($lt | index($words[$hit[0]])) // 0) as $at
           | ($at - 40 | if . < 0 then 0 else . end) as $from
           | (if $from > 0 then "…" else "" end)
             + ($t[$from:$from + 400] | gsub("[\\s]+"; " ") | .[0:160]))] | @tsv' "${_words[@]}") || true
  [[ -n "$_hits" ]] || return 1

  # Per transcript: keep it only if its messages cover every word, and pick the
  # snippet (most words hit, then newest). Then dedupe bridged copies of one
  # session (same id in several project dirs) to the newest, and sort by mtime.
  zmodload -F zsh/stat b:zstat
  local -A _cover _best _bscore _bts _bcwd _seen
  local _f _ts _cwd _hw _snip _k _n
  while IFS=$'\t' read -r _f _ts _cwd _hw _snip; do
    for _k in "${(@s:,:)_hw}"; do _cover[$_f]+="|$_k|"; done
    _n=${#${(@s:,:)_hw}}
    if (( _n > ${_bscore[$_f]:-0} )) || { (( _n == ${_bscore[$_f]:-0} )) && [[ "$_ts" > "${_bts[$_f]:-}" ]]; }; then
      _bscore[$_f]=$_n _bts[$_f]=$_ts _best[$_f]=$_snip _bcwd[$_f]=$_cwd
    fi
  done <<< "$_hits"

  local -a _rows
  local -a _st
  local _ok _mt _id
  for _f in "${(@k)_best}"; do
    _ok=1
    for _k in {0..$(( $#_words - 1 ))}; do
      [[ "${_cover[$_f]}" == *"|$_k|"* ]] || { _ok=0; break; }
    done
    (( _ok )) || continue
    zstat -A _st +mtime -- "$_f" 2>/dev/null || continue
    _rows+=("$_st[1]"$'\t'"$_f")
  done
  (( $#_rows )) || return 1
  local _row
  for _row in "${(@On)_rows}"; do
    _f=${_row#*$'\t'} _mt=${_row%%$'\t'*}
    _id=${_f:t:r}
    [[ -n "${_seen[$_id]:-}" ]] && continue
    _seen[$_id]=1
    print -r -- "$_mt"$'\t'"$_id"$'\t'"${_bcwd[$_f]}"$'\t'"$_f"$'\t'"${_best[$_f]}"
  done
}

frame_session_recent() {
  # frame_session_recent [N] — the N (default 100) most recently active claude
  # sessions you typed in, newest first, in frame_session_search's row shape:
  #   EPOCH  SESSION_ID  CWD  TRANSCRIPT  SNIPPET
  # SNIPPET is the FIRST message you typed (what the session was for); CWD is
  # where the last one was typed. Same filters as the search: headless
  # (sdk-cli) runs and sessions with nothing typed are dropped, and bridged
  # copies of one session collapse to the newest. Returns 1 when there are none.
  # With --resumable, only sessions frame shell can resume are listed, with
  # CWD the dir it resumes them in (see frame_session_resume_dir) — checked from each transcript's tail BEFORE
  # the full parse, so skipped worktree sessions cost next to nothing.
  emulate -L zsh
  setopt pipefail
  local _resumable=0
  [[ "${1:-}" == --resumable ]] && { _resumable=1; shift; }
  local _max=${1:-100}
  zmodload -F zsh/stat b:zstat
  # Newest transcripts first, one per session id; read a few extra since some
  # turn out to be headless or empty.
  local -a _all _files _st
  local -A _seen
  local _f _id _lcwd
  _all=( "$HOME/.claude/projects"/*/*.jsonl(N.om) )
  local -A _okdir _lastcwd
  local _chunk=$(( _max * 4 )) _i=1
  # In chunks, so --resumable reads only as many tails as it needs.
  while (( _i <= $#_all && $#_files < _max * 2 )); do
    local -a _batch=( "${(@)_all[_i,_i+_chunk-1]}" )
    (( _i += _chunk ))
    local -A _lc=()
    if (( _resumable )); then
      while IFS=$'\t' read -r _f _lcwd; do _lc[$_f]=$_lcwd; done \
        < <(frame_session_last_cwds "${_batch[@]}")
    fi
    for _f in "${_batch[@]}"; do
      _id=${_f:t:r}
      [[ -n "${_seen[$_id]:-}" ]] && continue
      _seen[$_id]=1
      if (( _resumable )); then
        _lcwd=${_lc[$_f]:-}
        [[ -n "$_lcwd" ]] || continue
        if [[ -z "${_okdir[$_lcwd]+x}" ]]; then
          _okdir[$_lcwd]=$(frame_session_resume_dir "$_lcwd") || _okdir[$_lcwd]=""
        fi
        [[ -n "${_okdir[$_lcwd]}" ]] || continue
        _lastcwd[$_f]=${_okdir[$_lcwd]}
      fi
      _files+=("$_f")
      (( $#_files >= _max * 2 )) && break
    done
  done
  (( $#_files )) || return 1

  local _hits
  _hits=$(perl -ne '
      next unless index($_, q{"type":"user"}) >= 0;
      next if index($_, q{"type":"tool_result"}) >= 0;
      s/"data":"[^"]{200,}"/"data":""/g;
      print "$ARGV:$_";' -- "${_files[@]}" \
    | jq -R -r '
        capture("^(?<f>[^:]*\\.jsonl):(?<j>.*)$")? | . as $l
        | ($l.j | fromjson?) // empty
        | select(type == "object" and .type == "user"
                 and .isMeta != true and .isSidechain != true
                 and .isCompactSummary != true
                 and .entrypoint != "sdk-cli")
        | (.message.content
           | if type == "string" then .
             else [.[]? | select(.type? == "text") | .text] | join("\n") end) as $t
        | select($t != "")
        | select($t | test("^\\s*(<(command-|local-command|system-reminder|task-notification|bash-|user-prompt)|Caveat:)") | not)
        | [$l.f, (.cwd // "?"), ($t | sub("^\\s+"; "") | gsub("[\\s]+"; " ") | .[0:160])] | @tsv') || true
  [[ -n "$_hits" ]] || return 1

  local -A _first _cwd
  local _c _snip
  while IFS=$'\t' read -r _f _c _snip; do
    [[ -n "${_first[$_f]:-}" ]] || _first[$_f]=$_snip
    _cwd[$_f]=$_c
  done <<< "$_hits"

  local _n=0
  for _f in "${_files[@]}"; do      # already newest first
    [[ -n "${_first[$_f]:-}" ]] || continue
    zstat -A _st +mtime -- "$_f" 2>/dev/null || continue
    print -r -- "$_st[1]"$'\t'"${_f:t:r}"$'\t'"${_lastcwd[$_f]:-${_cwd[$_f]}}"$'\t'"$_f"$'\t'"${_first[$_f]}"
    (( ++_n >= _max )) && break
  done
  (( _n ))
}

frame_session_running() {
  # frame_session_running — print "SESSION_ID<tab>PID" for each claude session
  # open right now. Claude Code keeps ~/.claude/sessions/<pid>.json (with its
  # sessionId) per live interactive session; a file whose pid is dead is stale
  # debris and skipped. That dir is Claude Code internals, not an API — if it
  # moves, this prints nothing and sessions just stop showing as running.
  emulate -L zsh
  local _f _pid _id
  for _f in "$HOME/.claude/sessions"/<->.json(N.); do
    _pid=${_f:t:r}
    kill -0 "$_pid" 2>/dev/null || continue
    _id=$(jq -r '.sessionId // empty' "$_f" 2>/dev/null) || continue
    [[ -n "$_id" ]] && print -r -- "$_id"$'\t'"$_pid"
  done
  return 0
}

frame_proc_env() {
  # frame_proc_env PID VAR — echo VAR from a running process's environment (one
  # of yours), or return 1. Linux reads /proc; macOS asks `ps -E`, which
  # appends the env to the command line — a VAR=value word in there. macOS
  # hides the env of Apple-signed binaries (/bin/sleep, /bin/zsh…) even from
  # their owner; claude isn't one, so its env reads fine.
  emulate -L zsh
  local _pid=$1 _var=$2 _w
  if [[ -r /proc/$_pid/environ ]]; then
    for _w in "${(@0)$(</proc/$_pid/environ)}"; do
      [[ "$_w" == "$_var="* ]] && { print -r -- "${_w#*=}"; return 0; }
    done
    return 1
  fi
  for _w in ${=$(ps -E -p "$_pid" -o command= 2>/dev/null)}; do
    [[ "$_w" == "$_var="* ]] && { print -r -- "${_w#*=}"; return 0; }
  done
  return 1
}

frame_session_last_cwds() {
  # frame_session_last_cwds TRANSCRIPT… — print "TRANSCRIPT<tab>CWD" for each,
  # CWD the dir the session last ran in (frame_session_cwd's answer), from one
  # perl pass over each file's tail — no jq per transcript.
  emulate -L zsh
  (( $# )) || return 0
  perl -e '
      for my $f (@ARGV) {
        open(my $fh, "<", $f) or next;
        my $size = -s $fh; my $off = $size > 262144 ? $size - 262144 : 0;
        seek($fh, $off, 0); local $/; my $buf = <$fh>; close $fh;
        my $cwd;
        while ($buf =~ /"cwd":"((?:[^"\\]|\\.)*)"/g) { $cwd = $1 }
        next unless defined $cwd;
        $cwd =~ s/\\(.)/$1/g;
        print "$f\t$cwd\n";
      }' -- "$@"
}

frame_session_dir_resumable() {
  # frame_session_dir_resumable DIR — can `frame shell` resume a session that
  # last ran in DIR? Not when DIR:
  #   - is gone (resuming there would just error — frame_session_resume_dir
  #     maps a gone `frame wt` worktree to its primary checkout instead), or
  #   - is your home dir (frame shell won't boot there), or
  #   - sits in a git linked worktree (a `frame wt` frame, `_REPO-TOPIC`):
  #     those belong to their worktree frame — `frame wt --from` hands them on.
  emulate -L zsh
  local _d=$1
  [[ "$_d" == /* && -d "$_d" ]] || return 1
  _d=${_d:A}
  [[ "$_d" != "${HOME:A}" ]] || return 1
  # Walk up to the nearest .git: a FILE pointing into some repo's
  # .git/worktrees/ marks a linked worktree (a submodule's points into
  # .git/modules/, and a plain checkout has a .git dir).
  while :; do
    [[ -d "$_d/.git" ]] && return 0
    if [[ -f "$_d/.git" ]]; then
      [[ "$(<"$_d/.git")" == *"/worktrees/"* ]] && return 1
      return 0
    fi
    [[ "$_d" == / ]] && return 0
    _d=${_d:h}
  done
}

frame_session_resume_dir() {
  # frame_session_resume_dir DIR — echo the dir `frame shell` resumes a session
  # in when it last ran in DIR, or return 1 if it can't be resumed there:
  #   - DIR still exists and frame_session_dir_resumable accepts it → DIR.
  #   - DIR is gone but sat in a torn-down `frame wt` worktree
  #     (…/_<REPO>-<TOPIC>[/sub]) → that repo's primary checkout,
  #     …/<REPO>. A frame's worktree dies at teardown but its transcript
  #     doesn't, so this is how a closed frame's conversation comes back.
  #   - anything else (a live worktree, ~, a gone non-worktree dir) → 1.
  emulate -L zsh
  local _d=$1
  [[ "$_d" == /* ]] || return 1
  if [[ -d "$_d" ]]; then
    frame_session_dir_resumable "$_d" || return 1
    print -r -- "${_d:A}"
    return 0
  fi
  frame_gone_worktree_main "$_d"
}

frame_gone_worktree_main() {
  # frame_gone_worktree_main DIR — DIR (or an ancestor) is a removed `frame wt`
  # worktree, ${MAIN_WT:h}/_<NAME>-<TOPIC> (wt.sh): echo the primary checkout
  # ${MAIN_WT:h}/<NAME>, or return 1. git forgets a worktree at removal, so the
  # path is all there is: walk up to the topmost missing component, which must
  # be `_…`, then try sibling checkouts named by its dash-prefixes, longest
  # first (_common-goal-fitness-88 → common-goal-fitness-88? common-goal-fitness ✓).
  # Only a plain checkout (a .git DIR) counts — not another linked worktree.
  emulate -L zsh
  local _p=$1
  while [[ ! -d "${_p:h}" ]]; do
    _p=${_p:h}
    [[ "$_p" == / ]] && return 1
  done
  local _base=${_p:t}
  [[ "$_base" == _?*-?* ]] || return 1
  local _cand=${_base#_} _m
  while [[ "$_cand" == *-* ]]; do
    _cand=${_cand%-*}
    _m="${_p:h}/$_cand"
    if [[ -d "$_m/.git" && "${_m:A}" != "${HOME:A}" ]]; then
      print -r -- "${_m:A}"
      return 0
    fi
  done
  return 1
}

frame_session_resumable() {
  # frame_session_resumable [N] — filter frame_session_search / _recent rows
  # (stdin) down to the sessions `frame shell` can actually resume (see
  # frame_session_resume_dir), at most N (default all). The CWD column is
  # rewritten to the dir --resume boots in: where the session LAST ran, or the
  # primary checkout when that was a since-removed `frame wt` worktree.
  emulate -L zsh
  local _max=${1:-0} _rows
  _rows=$(cat)
  [[ -n "$_rows" ]] || return 1
  local -a _files
  local _mt _id _cwd _f _snip
  while IFS=$'\t' read -r _mt _id _cwd _f _snip; do
    [[ -n "$_f" ]] && _files+=("$_f")
  done <<< "$_rows"
  local -A _last _rdir
  while IFS=$'\t' read -r _f _cwd; do
    _last[$_f]=$_cwd
  done < <(frame_session_last_cwds "${_files[@]}")

  local _n=0
  while IFS=$'\t' read -r _mt _id _cwd _f _snip; do
    [[ -n "$_id" ]] || continue
    _cwd=${_last[$_f]:-$_cwd}
    if [[ -z "${_rdir[$_cwd]+x}" ]]; then
      _rdir[$_cwd]=$(frame_session_resume_dir "$_cwd") || _rdir[$_cwd]=""
    fi
    _cwd=${_rdir[$_cwd]}
    [[ -n "$_cwd" ]] || continue
    print -r -- "$_mt"$'\t'"$_id"$'\t'"$_cwd"$'\t'"$_f"$'\t'"$_snip"
    (( ++_n == _max )) && break
  done <<< "$_rows"
  (( _n ))
}

frame_trust_dir() {
  # frame_trust_dir DIR — pre-accept Claude Code's "Accessing workspace / do you
  # trust this folder?" dialog for DIR, so a fresh worktree's claude boots
  # straight to a prompt. Claude records trust per absolute path in
  # ~/.claude.json as .projects[DIR].hasTrustDialogAccepted, and every new
  # worktree is a new path — so each one prompted, even under a trusted parent
  # (a folder whose .claude/settings*.json pre-approves tools gets its own
  # check). There is no CLI flag that skips it interactively
  # (--dangerously-skip-permissions doesn't), so seed the key.
  #
  # Best-effort, never fatal: skipped without jq or before claude has ever
  # written ~/.claude.json, and a no-op when DIR is already trusted (so reboots
  # don't rewrite a file live claudes also write). The write goes via a temp
  # file in the same dir + mv, so a concurrent claude sees old-or-new, never a
  # torn file; the worst race loses this key and the dialog shows once.
  emulate -L zsh
  local _dir="${1:A}"
  local _cfg="$HOME/.claude.json"
  command -v jq >/dev/null 2>&1 || return 0
  [[ -f "$_cfg" ]] || return 0
  _cfg="${_cfg:A}"    # write through a symlinked config, don't replace the link
  jq -e --arg p "$_dir" '.projects[$p].hasTrustDialogAccepted == true' \
    "$_cfg" >/dev/null 2>&1 && return 0
  local _tmp
  _tmp=$(mktemp "${_cfg:h}/.claude.json.frame.XXXXXX") || return 0
  if jq --arg p "$_dir" \
      '.projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})' \
      "$_cfg" > "$_tmp" 2>/dev/null && [[ -s "$_tmp" ]]; then
    chmod "$(stat -f %Lp "$_cfg" 2>/dev/null || stat -c %a "$_cfg")" "$_tmp" 2>/dev/null
    mv -f "$_tmp" "$_cfg"
  else
    rm -f "$_tmp"
  fi
  return 0
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
    jq)     print -r -- "'brew install jq' (or your package manager's jq)" ;;
    perl)   print -r -- "ships with macOS and most Linux distros; else your package manager's perl" ;;
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

frame_is_macos() {
  # The gate for the macOS-only surfaces: window management (focus/spawn ride
  # AppleScript, not Ghostty IPC — Linux Ghostty doesn't help) and banner
  # plumbing. Everything else — worktrees, broker, layout, services — is
  # platform-agnostic and must never call this.
  [[ "$OSTYPE" == darwin* ]]
}

# ── claude-code hooks ─────────────────────────────────────────────────────────

# claude/hooks.json — the claude-code hooks every frame's claude runs with,
# passed as `claude --settings ~/.local/share/frame/claude-hooks.json`, a copy
# kept in step with this file (see frame_export_claude_flags), so no
# project or shell dir needs its own .claude/settings.json. Claude Code merges
# these with the dir's own settings and runs an identical hook only once, so a
# repo still carrying frame's hooks in a committed settings.json doesn't fire
# them twice. The hooks:
#   Stop             → `frame notify` (banner + "waiting" title status) and
#                      `frame reply` (routes the turn's last message to anyone
#                      who req'd this frame)
#   UserPromptSubmit → `frame status --prompt` ("working" + the turn stamp)
#   Notification     → `frame notify --blocked` ("blocked" + banner) when claude
#                      pauses MID-turn on a permission prompt — the one state
#                      Stop/UserPromptSubmit can't see
#   SessionStart     → `frame swarm --context` (frame-awareness block, iff the
#                      swarm level is ≥1; the dial decides what it emits)
#   PostToolUse      → `frame reload-editor` (Edit|Write|MultiEdit|NotebookEdit:
#                      reload the edited file into this frame's nvim buffer)
# `frame reply` and `frame reload-editor` read the hook JSON on stdin; the
# redirects touch stdout/stderr only. Every hook is `… || true`, so a failure
# never disrupts claude.
frame_claude_hooks_file() {
  print -r -- "$FRAME_ROOT/claude/hooks.json"
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

frame_shell_home() {
  # Where `frame spawn shell` workers get their scratch dirs (TOPIC/ under it):
  # $FRAME_SHELL_HOME, default ~/.local/share/frame/shells, beside frame's other
  # files. (Was ~/frames; set FRAME_SHELL_HOME=~/frames to keep that.)
  print -r -- "${FRAME_SHELL_HOME:-$HOME/.local/share/frame/shells}"
}

frame_mint_shell_topic() {
  # Mint a fresh dated scratch topic (2026-07-30-a3f9) that collides with no
  # existing dir under frame_shell_home, and print it. Used by `frame spawn
  # shell` when no TOPIC is given, so a bare spawn always lands somewhere new
  # instead of reusing another worker's scratch.
  local _home=$(frame_shell_home) _topic
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

frame_reap_orphans_in() {
  # frame_reap_orphans_in DIR — after a frame's nvim has exited, stop whatever
  # it left running inside DIR so nothing writes there once the worktree is
  # gone. The case: a dev server (astro/vite) that survived the Ctrl-C and the
  # SIGHUP, reparented to launchd, keeps regenerating its gitignored cache
  # (.astro/, node_modules/.vite/). Its mkdir -p recreates the worktree dir
  # right after git removed it, leaving a cache-only husk in the repos dir.
  #
  # First wait a few seconds for holders to exit on their own (terminal jobs
  # linger a beat after nvim dies). Then SIGTERM the survivors that are
  # ORPHANS — reparented to pid 1, or descended from such a process — and
  # SIGKILL any that ignore it. A holder that still has a live parent (your
  # own shell cd'd into the worktree from another tab) is never signalled,
  # only reported. Prints one line per process it stopped. Best-effort: no
  # lsof → nothing found → no-op.
  emulate -L zsh
  local _dir=$1 _i _pid _cmd _p _hold
  local -a _pids _orph
  local -A _ppid _name
  for _i in {1..25}; do
    _hold=$(frame_dir_in_use "$_dir")
    [[ -z "$_hold" ]] && return 0
    sleep 0.2
  done
  while read -r _pid _cmd; do
    [[ "$_pid" == <1-> && "$_pid" != $$ ]] || continue
    _pids+=("$_pid") _name[$_pid]=$_cmd
  done <<< "$_hold"
  for _pid in "${_pids[@]}"; do
    # Walk up the parent chain: an orphan is one whose chain reaches pid 1
    # before hitting a living process that isn't itself a holder.
    _p=$_pid
    while :; do
      _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')
      [[ -z "$_p" ]] && break
      if [[ "$_p" == 1 ]]; then _orph+=("$_pid"); break; fi
      [[ -n "${_name[$_p]:-}" ]] || break   # parent is alive and outside DIR
    done
  done
  for _pid in "${_pids[@]}"; do
    (( ${_orph[(Ie)$_pid]} )) && continue
    print -r -- "$WARN_MARK still running in $_dir (not ours to stop): $_pid ${_name[$_pid]}" >&2
  done
  (( $#_orph )) || return 0
  kill -TERM "${_orph[@]}" 2>/dev/null
  for _i in {1..15}; do
    kill -0 "${_orph[@]}" 2>/dev/null || break
    sleep 0.2
  done
  for _pid in "${_orph[@]}"; do
    kill -0 "$_pid" 2>/dev/null && kill -KILL "$_pid" 2>/dev/null
    print -r -- "stopped leftover process $_pid ${_name[$_pid]}"
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
  # Auto-start is OrbStack-only. Anywhere `open -a OrbStack` can't work —
  # Linux, or a mac without OrbStack — fail with instructions rather than
  # entering the wait loop: docker will never come up on its own there, and
  # the until-loop would hang forever.
  if ! docker info >/dev/null 2>&1; then
    if ! frame_is_macos; then
      echo "$X_MARK docker isn't running — auto-start is OrbStack (macOS) only;" >&2
      echo "  start your docker daemon (e.g. 'systemctl start docker') and retry" >&2
      return 1
    fi
    echo "$RUN_MARK starting OrbStack…"
    if ! open -a OrbStack 2>/dev/null; then
      echo "$X_MARK couldn't launch OrbStack — start your docker provider and retry" >&2
      return 1
    fi
    until docker info >/dev/null 2>&1; do sleep 0.5; done
  fi
}

frame_services_up() {
  # frame_services_up [postgres] [minio] — start (default: both) and wait ready.
  # Compose interpolates FRAME_PG_*/FRAME_MINIO_* credential overrides from the
  # environment; source the machine config here too so `frame services up` from
  # a bare shell (no frame_load_config) still sees them.
  frame_source_machine_config
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
        pg_isready -U "${FRAME_PG_USER:-frame}" -d frame >/dev/null 2>&1; do
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
         psql -U "${FRAME_PG_USER:-frame}" -d frame -v ON_ERROR_STOP=1 -qAt)
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

# ── node_modules cloning ──────────────────────────────────────────────────────

_frame_deps_fingerprint() {
  # _frame_deps_fingerprint [DIR] — what DIR's node_modules should have been
  # installed from: sha of package.json (+ package-lock.json) plus node version.
  local d=${1:-.} files
  files=("$d/package.json"); [ -f "$d/package-lock.json" ] && files+=("$d/package-lock.json")
  print -r -- "$(cat "${files[@]}" | shasum -a 256 | cut -d' ' -f1)-node$(node -v)"
}

_frame_reconcile_deps() {
  # _frame_reconcile_deps DIR — npm install in DIR iff its node_modules is
  # missing or its .deps-stamp doesn't match DIR's fingerprint; then stamp it.
  # Never touches a symlinked node_modules (legacy shared-primary worktree).
  local d=$1 stamp="$1/node_modules/.deps-stamp"
  [ -L "$d/node_modules" ] && return 0
  [ -d "$d/node_modules" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$(_frame_deps_fingerprint "$d")" ] \
    && return 0
  ( cd "$d" && npm install --no-audit --no-fund ) || return 1
  _frame_deps_fingerprint "$d" > "$stamp"   # recompute: install may rewrite the lockfile
}

frame_clone_node_modules() {
  # frame_clone_node_modules — give THIS worktree its own node_modules cheaply.
  # Call it from a project's stack_up hook (npm-based projects). Runs in the
  # worktree with $MAIN_WT set; idempotent.
  #
  #   1. Reconcile the primary checkout first (the clone source): install there
  #      when its node_modules is missing or doesn't match its own package.json
  #      + lockfile + node version (a .deps-stamp kept in the primary too). A
  #      primary installed before a dep upgrade and never refreshed would
  #      otherwise hand every new worktree a stale tree.
  #   2. Seed a fresh worktree's node_modules from the primary. The fast path is
  #      an APFS clonefile (`cp -c`: copy-on-write, ~0 disk, ~instant); on a
  #      filesystem without clonefile support it falls back to a plain recursive
  #      copy (correct, just not free). The clone carries the primary's stamp,
  #      so a worktree whose deps match the primary's skips the install, and
  #      one that differs reconciles with `npm install`. A per-worktree
  #      node_modules keeps each frame's .vite/.astro dep-optimizer cache its
  #      own, so parallel dev servers stop fighting.
  # The no-op path is two fingerprint checks (~100ms).

  # Serialize primary installs: parallel `frame wt` spawns must not run two
  # npm installs in the same tree. mkdir is the atomic lock; a lock older than
  # 10 minutes is a crashed run and is broken.
  local lock="$MAIN_WT/.git/frame-deps.lock"
  [ -d "$MAIN_WT/.git" ] || lock="${TMPDIR:-/tmp}/frame-deps-${${MAIN_WT:A}//\//_}.lock"
  until mkdir "$lock" 2>/dev/null; do
    [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null
    sleep 0.5
  done
  _frame_reconcile_deps "$MAIN_WT"; local rc=$?
  rmdir "$lock" 2>/dev/null
  (( rc == 0 )) || return $rc
  [ "${PWD:A}" = "${MAIN_WT:A}" ] && return 0   # primary owns the real node_modules

  # Fresh worktree: clone the primary's node_modules (copy-on-write).
  if [ ! -e node_modules ]; then
    cp -Rc "$MAIN_WT/node_modules" node_modules 2>/dev/null \
      || { rm -rf node_modules; cp -R "$MAIN_WT/node_modules" node_modules; }
  fi

  _frame_reconcile_deps .
}

# ── misc ──────────────────────────────────────────────────────────────────────

frame_export_ports() {
  # Free ports, scanned upward from the project's primary-env defaults (primary
  # on 3000/5173/24678 → first worktree 3001/5174/24679, and so on). Exported
  # under the rename-proof FRAME_* names app code should read, plus the
  # project-prefixed aliases for code already reading those. A config with no
  # API_PORT/VITE_PORT gets none — FRAME_VITE_PORT stays empty. Reads
  # API_PORT/VITE_PORT/HMR_PORT/PORT_PREFIX from the sourced project config.
  FRAME_VITE_PORT=""
  if [[ -n "${API_PORT:-}${VITE_PORT:-}" ]]; then
    local _hmr
    export PORT=$(find_free_port "${API_PORT:-3000}")
    FRAME_VITE_PORT=$(find_free_port "${VITE_PORT:-5173}")
    _hmr=$(find_free_port "${HMR_PORT:-24678}")
    export FRAME_API_PORT=$PORT
    export FRAME_HMR_PORT=$_hmr
    export "${PORT_PREFIX}_API_PORT=$PORT"
    export "${PORT_PREFIX}_VITE_PORT=$FRAME_VITE_PORT"
    export "${PORT_PREFIX}_HMR_PORT=$_hmr"
    echo "$OK_MARK frame env: server :$PORT · vite :$FRAME_VITE_PORT · hmr :$_hmr"
  fi
}

find_free_port() {
  # Scan upward from $1 until a port nothing is listening on.
  local _p=$1
  while lsof -nP -iTCP:$_p -sTCP:LISTEN >/dev/null 2>&1; do
    _p=$((_p + 1))
  done
  echo $_p
}
