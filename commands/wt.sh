# frame wt — worktree dev bootstrap (generic port of dev-worktree.sh).
#
#   frame wt TOPIC     create (or reuse) branch TOPIC and worktree
#                      ../_<NAME>-TOPIC beside the primary checkout, boot it
#   frame wt           boot the worktree you're already in
#   frame wt TOPIC --from SRC        boot TOPIC's claude resuming SRC frame's
#                      warm session (its newest transcript); --resume ID takes a
#                      raw session id instead. Carries context across frames.
#                      SRC is a bare topic (this project) or a NAME/TOPIC handle
#                      (any project — the form :FrameName / `frame name` copy).
#                      A LIVE source is handed off gracefully: its claude is
#                      asked to wrap up and retire its own frame (frame wt -d),
#                      and resumed here once it's down (FRAME_HANDOFF_TIMEOUT,
#                      default 300s, bounds the wait).
#   frame wt -d [-f] [TOPIC]
#                      tear down: quit the nvim session, remove worktree,
#                      delete branch. TOPIC defaults to the frame you're
#                      standing in (teardown is handed to a detached reaper so
#                      it survives its own nvim dying). Refuses if the worktree
#                      is dirty or the branch isn't merged; -f overrides.
#
# Every frame is a self-sufficient peer: this runs the project's stack_up
# (idempotent — first boot brings up the shared services, later boots no-op)
# and gives the worktree its OWN server and vite on free ports, scanned upward
# from the project's defaults, exported with the project's PORT_PREFIX so its
# code (e.g. web/vite.config.ts) picks them up. The primary checkout is just
# the git anchor merges land on; it never needs a dev session.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

frame_load_config

# -d [-f] [TOPIC]: gracefully quit the nvim session, then remove the
# worktree + branch. Works from inside the target frame too — see below.
if [[ "${1:-}" == "-d" ]]; then
  shift
  FORCE=0 TOPIC=""
  for _arg in "$@"; do
    case "$_arg" in
      -f|--force) FORCE=1 ;;
      -*) echo "$X_MARK unknown flag: $_arg" >&2; exit 2 ;;
      *)
        if [[ -n "$TOPIC" ]]; then
          echo "$X_MARK more than one topic given ($TOPIC, $_arg)" >&2; exit 2
        fi
        TOPIC=$_arg ;;
    esac
  done
  if [[ -z "$TOPIC" ]]; then
    if [[ "${PROJECT_ROOT:t}" == _$NAME-* ]]; then
      TOPIC="${${PROJECT_ROOT:t}#_$NAME-}"
    else
      echo "Usage: frame wt -d [-f] [TOPIC]  (TOPIC only optional inside a frame)" >&2
      exit 1
    fi
  fi

  WT_DIR="${MAIN_WT:h}/_$NAME-$TOPIC"
  SOCKET="$FRAME_RUNDIR/$NAME-$TOPIC.nvim"
  if [[ ! -d "$WT_DIR" ]]; then
    echo "$X_MARK no worktree at $WT_DIR" >&2; exit 1
  fi

  # Safety rails run BEFORE touching nvim — failing after the editor is gone
  # would leave a half-torn-down frame with no session to fix it from.
  if (( ! FORCE )); then
    if [[ -n "$(git -C "$WT_DIR" status --porcelain)" ]]; then
      echo "$X_MARK $WT_DIR has uncommitted/untracked files — commit or stash them," >&2
      echo "  or discard with: frame wt -d -f $TOPIC" >&2
      exit 1
    fi
    MAIN_BRANCH=$(git -C "$MAIN_WT" rev-parse --abbrev-ref HEAD)
    if ! git -C "$MAIN_WT" merge-base --is-ancestor "$TOPIC" "$MAIN_BRANCH"; then
      echo "$X_MARK branch $TOPIC has commits not on $MAIN_BRANCH — merge first" >&2
      echo "  (frame merge $TOPIC), or discard with: frame wt -d -f $TOPIC" >&2
      exit 1
    fi
  fi

  # Standing inside the target frame: this shell is a terminal buffer of the
  # nvim about to die, and its cwd is inside the worktree about to be removed —
  # an inline teardown would kill itself halfway. Hand off to a detached
  # re-invocation rooted in MAIN_WT; nohup shields it from the SIGHUP that
  # nvim's exit sends this terminal.
  if [[ "${PROJECT_ROOT:A}" == "${WT_DIR:A}" ]]; then
    _log="$FRAME_RUNDIR/$NAME-$TOPIC.teardown.log"
    _flags=(); if (( FORCE )); then _flags=(-f); fi
    echo "$RUN_MARK tearing down $TOPIC from inside — handing off to a detached reaper"
    echo "  (log: $_log). nvim will quit and this window will close; if no nvim"
    echo "  is running, cd out of the removed directory afterwards."
    cd "$MAIN_WT"
    nohup "$FRAME_ROOT/bin/frame" wt -d "${_flags[@]}" "$TOPIC" >"$_log" 2>&1 &
    exit 0
  fi

  # Track whether we POSITIVELY saw the session go down. Only a clean :qa!
  # handshake followed by the socket unlinking proves it; a missing or
  # unresponsive socket does not (see the backstop below).
  _confirmed_down=0
  if [[ -S "$SOCKET" ]]; then
    echo "$RUN_MARK sending :qa! to nvim ($SOCKET)…"
    # <Cmd>qa!<CR> executes from ANY mode — the session normally sits in
    # terminal-insert mode, where raw ':qa!' keys would just be typed into the
    # foreground program. The ! also bypasses :qa guards in a user's vimrc.
    if nvim --server "$SOCKET" --remote-send '<Cmd>qa!<CR>' 2>/dev/null; then
      # nvim unlinks its socket on exit — poll for that instead of blind sleep.
      for _i in {1..50}; do
        [[ -e "$SOCKET" ]] || break
        sleep 0.2
      done
      if [[ -e "$SOCKET" ]]; then
        echo "$X_MARK nvim still running after 10s — aborting teardown" >&2
        exit 1
      fi
      _confirmed_down=1   # acked :qa! and unlinked its socket — really gone
    else
      echo "⚠ socket is stale (no nvim listening) — removing it"
      rm -f "$SOCKET"
    fi
  else
    echo "⚠ no nvim socket at $SOCKET — session may already be closed"
  fi

  # Backstop before anything destructive, for the case we did NOT confirm the
  # session down. A missing or unresponsive socket is NOT proof the editor is
  # gone: after the rundir moved to $FRAME_RUNDIR a pre-move session still
  # listens on a legacy /tmp path, and a wedged nvim won't answer the handshake
  # above — either way this code used to fall straight through and delete the
  # worktree out from under a live process, orphaning the editor and stranding
  # its shell in a husk directory (the exact bug this guards). So refuse when a
  # live process still holds the worktree as its cwd. Skipped when :qa! already
  # confirmed the exit (its terminal children may linger a beat and would else
  # false-positive) and skipped under -f for the deliberate nuke.
  if (( ! FORCE && ! _confirmed_down )); then
    _holders=$(frame_dir_in_use "$WT_DIR")
    if [[ -n "$_holders" ]]; then
      echo "$X_MARK $WT_DIR is still in use — not removing it:" >&2
      print -r -- "$_holders" | sed 's/^/    /' >&2
      echo "  quit that session/shell first (it may be an orphaned nvim whose" >&2
      echo "  socket moved), or force with: frame wt -d -f $TOPIC" >&2
      exit 1
    fi
  fi
  # git worktree remove races a lingering dev server. :qa! kills nvim, whose
  # exit SIGHUPs the vite/astro job it hosted — but an orphaned child can keep
  # regenerating gitignored caches (.astro/, node_modules/.vite/) for a beat.
  # git unregisters the worktree and deletes its tracked files, then its final
  # rmdir trips over a cache the child recreated in that window and fails
  # "Directory not empty" (non-zero). Under set -e that aborted teardown right
  # HERE — before the branch delete below — stranding an orphaned branch beside
  # a husk dir git no longer tracks: the "missed worktree" this repairs. So
  # tolerate that specific failure. If git still has the worktree registered the
  # removal genuinely failed (something holds it) and we surface it; otherwise
  # git got as far as unregistering and only the leftover-dir rmdir lost the
  # race — finish its job by clearing the husk (same show-toplevel husk test the
  # boot path uses) and pruning the stale entry, so the branch delete still runs.
  _rm_flags=(); if (( FORCE )); then _rm_flags=(--force); fi
  if ! _rm_err=$(git -C "$MAIN_WT" worktree remove "${_rm_flags[@]}" "$WT_DIR" 2>&1); then
    if [[ "$(git -C "$WT_DIR" rev-parse --show-toplevel 2>/dev/null)" == "${WT_DIR:A}" ]]; then
      echo "$X_MARK could not remove worktree $WT_DIR:" >&2
      print -r -- "$_rm_err" | sed 's/^/    /' >&2
      exit 1
    fi
    rm -rf "$WT_DIR"
    git -C "$MAIN_WT" worktree prune
    echo "⚠ worktree dir lingered after removal (a dev server was still writing) — cleaned it up"
  fi
  git -C "$MAIN_WT" branch -D "$TOPIC"
  # Reap the recorded session id (frame swarm --context writes it) alongside the
  # worktree — a torn-down frame is no longer a valid `frame wt --from` source.
  rm -f "$FRAME_RUNDIR/$NAME-$TOPIC.session"
  # :FrameDown's watcher matches this line to know teardown finished without
  # reaching the session — keep the wording in sync with layouts/session.lua.
  echo "$OK_MARK removed worktree and branch $TOPIC"
  exit 0
fi

# Boot path (create-and-boot, or reboot the frame you're in). Parse optional
# flags and the positional TOPIC. --resume/--from carry a warm claude session
# INTO the new frame: --resume takes a raw session id, --from names a sibling
# frame whose newest session is resolved to its id (see below). Both end up as
# `claude --resume <id>` via FRAME_CLAUDE_FLAGS. The rest of the script is
# positional, so we normalize back to `$@` after parsing.
RESUME_ID="" FROM_TOPIC=""
_positional=()
while (( $# )); do
  case "$1" in
    --resume)   shift; RESUME_ID="${1:-}"
                [[ -n "$RESUME_ID" ]] || { echo "$X_MARK --resume needs a session id" >&2; exit 2; } ;;
    --resume=*) RESUME_ID="${1#--resume=}" ;;
    --from)     shift; FROM_TOPIC="${1:-}"
                [[ -n "$FROM_TOPIC" ]] || { echo "$X_MARK --from needs a source frame/topic" >&2; exit 2; } ;;
    --from=*)   FROM_TOPIC="${1#--from=}" ;;
    -m|--merge) echo "$X_MARK frame wt -m was removed — use: frame merge [TOPIC]" >&2; exit 2 ;;
    -*)         echo "$X_MARK unknown flag: $1" >&2; exit 2 ;;
    *)          _positional+=("$1") ;;
  esac
  shift
done
set -- "${_positional[@]}"

if [[ -n "$RESUME_ID" && -n "$FROM_TOPIC" ]]; then
  echo "$X_MARK --resume and --from are mutually exclusive" >&2; exit 2
fi

# --from SRC: resume that sibling frame's session into this new frame. SRC is
# either a bare TOPIC — resolved against THIS project, the historical
# same-project form — or the NAME/TOPIC handle that :FrameName / `frame name`
# hand you, naming a sibling in ANY project. That handle is the unambiguous form
# every other sibling-addressing command (req/focus/view/deliver) already takes;
# --from accepts it too so a copied :FrameName pastes straight in. A bare topic
# keeps the current project's NAME; a slash splits off the source project's name.
#
# A session must have ONE owner: two claudes appending the same transcript can
# corrupt it. So the source's claude must be gone before we resume its session
# here. Rather than refuse a live source (the old behavior — which forced you to
# tidy up, hunt down the right process, and quit it by hand), we hand off
# gracefully: ask the source's claude to wrap up and retire ITS OWN frame, then
# wait for it to go down before taking over. The source can't quit its own CLI
# keystroke-style, but it CAN run `frame wt -d` — that tears its frame down
# (killing its claude) in its own project context, respecting the dirty/unmerged
# guards, which doubles as the "commit first" nudge. Its going down is the
# unspoofable A-OK; we never force-kill.
#
# Resolve the id BEFORE any of this: prefer the one the source recorded at its
# last SessionStart ($FRAME_RUNDIR/<name>-<topic>.session, written by `frame
# swarm --context`) — authoritative, and correct even when the source was ITSELF
# resumed (its transcript keeps the origin frame's project key, so a path-scan
# finds nothing under its own worktree). Fall back to scanning the worktree's
# transcripts for frames that predate the recorder. Reading it up front means a
# source that retires itself (reaping its own .session) has already handed us the
# id, and we never retire a source only to find it had no session to carry.
if [[ -n "$FROM_TOPIC" ]]; then
  # Split the handle: NAME/TOPIC picks a source project explicitly; a bare topic
  # defaults to this project's NAME. TOPIC keeps any further slashes (branch-like
  # topics), matching frame_resolve_target's %%/* // #*/ split. Messages echo
  # $FROM_TOPIC verbatim — what the user typed, bare or handle.
  if [[ "$FROM_TOPIC" == */* ]]; then
    _from_name="${FROM_TOPIC%%/*}" _from_topic="${FROM_TOPIC#*/}"
  else
    _from_name="$NAME" _from_topic="$FROM_TOPIC"
  fi
  _src_sock="$FRAME_RUNDIR/$_from_name-$_from_topic.nvim"
  _sess_file="$FRAME_RUNDIR/$_from_name-$_from_topic.session"
  if [[ -r "$_sess_file" ]]; then
    RESUME_ID=$(<"$_sess_file")
  else
    RESUME_ID=$(frame_session_id_for_dir "${MAIN_WT:h}/_$_from_name-$_from_topic") || RESUME_ID=""
  fi
  if [[ -z "$RESUME_ID" ]]; then
    echo "$X_MARK --from $FROM_TOPIC: no claude session found for that frame" >&2
    echo "  (no $_sess_file, and no transcript under ~/.claude/projects for its worktree)" >&2
    exit 1
  fi

  # Graceful handoff, only when the source's claude is actually live. If it's
  # already stopped (0) there's nothing to hand off; if we can't tell (RPC error
  # — a source predating this probe) we warn and proceed rather than block.
  if [[ -S "$_src_sock" ]]; then
    _alive=$(frame_rpc_expr "$_src_sock" 'v:lua.FrameClaudeAlive()') || _alive=""
    if [[ "$_alive" == 1 ]]; then
      # The new frame's topic is still just the positional here ($1); TOPIC is
      # assigned further down. Name the destination for the nudge.
      _dest="$NAME/${1:-?}"
      _msg="🚚 frame handoff — your claude session is being moved into a new frame ($_dest). Please wrap up now: commit or stash any loose work on this branch and finish your current thought, then retire THIS frame yourself by running  frame wt -d  (it refuses on a dirty or unmerged branch — commit or merge first, or  frame wt -d -f  to discard). The moment this frame goes down, your session resumes in the new one. No reply needed."
      _esc=${_msg//\'/\'\'}                       # vimscript single-quote escape
      if ! frame_rpc_expr "$_src_sock" "v:lua.FrameBrokerSubmit('$_esc', 'inbox')" >/dev/null; then
        echo "$X_MARK couldn't hand off to frame $FROM_TOPIC — its session didn't take the" >&2
        echo "  message. Is it wedged? Tidy up and retire it yourself (frame wt -d from" >&2
        echo "  inside it, or :FrameDown), then rerun." >&2
        exit 1
      fi
      _timeout=${FRAME_HANDOFF_TIMEOUT:-300} _poll=${FRAME_HANDOFF_POLL:-3} _waited=0
      echo "$RUN_MARK asked $FROM_TOPIC to wrap up and retire itself — waiting for it to go"
      echo "  down (up to ${_timeout}s; it resumes here once it's down, Ctrl-C to abort)…"
      while (( _waited < _timeout )); do
        [[ -S "$_src_sock" ]] || break            # frame torn down → source gone
        _alive=$(frame_rpc_expr "$_src_sock" 'v:lua.FrameClaudeAlive()') || _alive=""
        [[ "$_alive" == 0 ]] && break             # claude exited (frame may linger)
        sleep "$_poll"; _waited=$(( _waited + _poll ))
      done
      if [[ -S "$_src_sock" && "${_alive:-1}" != 0 ]]; then
        echo "$X_MARK $FROM_TOPIC didn't go down within ${_timeout}s — its claude may be" >&2
        echo "  mid-task, or waiting on a dirty/unmerged branch it can't retire. Check it" >&2
        echo "  (frame view $FROM_TOPIC), let it finish or commit, then rerun. Nothing was" >&2
        echo "  created here." >&2
        exit 1
      fi
      echo "$OK_MARK $FROM_TOPIC is down — taking over its session."
    elif [[ -z "$_alive" ]]; then
      echo "$WARN_MARK couldn't check whether frame $FROM_TOPIC's claude is running (it" >&2
      echo "  predates this check — reboot it for precise detection). If its claude is" >&2
      echo "  up, retire it first (frame wt -d from inside it) to avoid corrupting the" >&2
      echo "  shared transcript." >&2
    fi
    # _alive == 0 → claude already stopped; nothing to hand off.
  fi
  echo "$OK_MARK resuming session $RESUME_ID from frame $FROM_TOPIC"
fi

# A raw --resume id flows straight onto claude's command line, so keep it to the
# UUID charset (defends the buffers.json `claude ${FRAME_CLAUDE_FLAGS}` split).
if [[ -n "$RESUME_ID" && ! "$RESUME_ID" =~ '^[A-Za-z0-9-]+$' ]]; then
  echo "$X_MARK not a valid session id: $RESUME_ID" >&2; exit 2
fi

# Ask before any side effect — a nested boot aborted here creates no worktree.
frame_guard_nested || exit 1

# BUFFERS is required to boot a frame, and authoritative even when empty:
# BUFFERS=() opens no buffers. Definitions live in $FRAME_ROOT/buffers.json;
# BUFFERS says which of them this project's frames open.
if (( ! ${+BUFFERS} )); then
  echo "$X_MARK frame: .frame/config.sh must define BUFFERS=(…) — the buffers to open" >&2
  echo "  (definitions: $FRAME_ROOT/buffers.json; e.g. BUFFERS=(claude local))" >&2
  exit 1
fi

# Resolve the topic first, before any worktree is created — the collision guard
# below must run before side effects, so a rejected topic leaves nothing behind.
if (( $# >= 1 )); then
  TOPIC=$1
  WT_DIR="${MAIN_WT:h}/_$NAME-$TOPIC"
  PROJECT_DIR="$WT_DIR"
else
  PROJECT_DIR="$PROJECT_ROOT"
  if [[ "$PROJECT_DIR" == "$MAIN_WT" ]]; then
    # Booting the primary checkout itself — no worktree dir to derive a topic
    # from, so use the branch name (usually `main`).
    TOPIC=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)
    # A topicless boot of the primary checkout on main/master is almost always a
    # slip: you meant `frame wt TOPIC` (with the topic) and dropped the argument.
    # The result is a frame with NO worktree of its own, which then baffles you
    # at teardown — `frame wt -d` / :FrameDown find nothing to remove. Confirm it
    # was deliberate. Interactive only: a scripted/agent boot has no TTY to
    # answer, so let it through (booting main harms nothing — it only confuses).
    case "$TOPIC" in
      main|master)
        if [[ -t 0 ]]; then
          _reply=""
          print -n "$WARN_MARK you're opening a frame on '$TOPIC' in the primary checkout with no TOPIC — this frame has no worktree, so there'll be nothing for :FrameDown to tear down. Did you mean \`frame wt <TOPIC>\`? Continue anyway? (y/N) "
          read -r _reply || _reply=""
          if [[ "$_reply" != [yY]* ]]; then
            echo "$X_MARK aborted — rerun as \`frame wt <TOPIC>\` to open a topic worktree" >&2
            exit 1
          fi
        fi
        ;;
    esac
  else
    TOPIC="${${PROJECT_DIR:t}#_$NAME-}"
  fi
fi

# Topics are the handle `frame focus TOPIC` matches on, and that match ignores
# the owner name — so a topic must be unique across every live frame or focus
# can't tell them apart. Refuse before creating/booting rather than let the
# collision exist. (Rebooting this same frame is exempt — see the helper.)
frame_assert_topic_free "$NAME" "$TOPIC" || exit 1

# Topic is clear — now materialize the worktree for the `frame wt TOPIC` form.
if (( $# >= 1 )); then
  if [[ -d "$WT_DIR" ]]; then
    # A directory here isn't automatically a healthy worktree to reuse. A
    # teardown that couldn't reach its session (or one racing this boot) can
    # leave the path behind as a husk — an empty dir git no longer tracks, or
    # one mid-removal. Booting into that gives a frame with no .git: services
    # come up, then the first file op (symlinking .env) fails in a cwd that has
    # since vanished — the cryptic "ln: .env: No such file or directory" this
    # replaces. Only reuse a dir git still recognizes as THIS worktree's root.
    if [[ "$(git -C "$WT_DIR" rev-parse --show-toplevel 2>/dev/null)" == "${WT_DIR:A}" ]]; then
      echo "$OK_MARK worktree $WT_DIR already exists — reusing"
    else
      echo "$X_MARK $WT_DIR exists but is not a live worktree — a torn-down or" >&2
      echo "  half-removed frame left it behind. Clear the stale directory, then retry:" >&2
      echo "      rm -rf ${(q)WT_DIR} && git -C ${(q)MAIN_WT} worktree prune" >&2
      exit 1
    fi
  elif git -C "$MAIN_WT" show-ref --verify --quiet "refs/heads/$TOPIC"; then
    echo "$RUN_MARK adding worktree $WT_DIR on existing branch $TOPIC…"
    git -C "$MAIN_WT" worktree add "$WT_DIR" "$TOPIC"
  else
    echo "$RUN_MARK creating branch $TOPIC + worktree $WT_DIR…"
    git -C "$MAIN_WT" worktree add -b "$TOPIC" "$WT_DIR"
  fi
fi

cd "$PROJECT_DIR"

set_title "$(frame_base_title "$NAME" "$TOPIC")"
frame_record_gtab "$NAME" "$TOPIC"

# Frames are self-sufficient: whichever boots first brings up the world.
# stack_up is idempotent (compose up -d no-ops, ensure_* helpers no-op), so
# this is cheap when the stack is already running.
if (( $+functions[stack_up] )); then stack_up; fi

# A concurrent teardown can pull the worktree out from under us during the work
# above — stack_up alone takes seconds. If our cwd has been unlinked, every file
# op below (starting with the .env symlink) fails with a bare ENOENT; surface
# the real cause once, here, instead of that cryptic error. Harmless for the
# primary checkout — MAIN_WT never gets reaped.
if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "$X_MARK $PROJECT_DIR vanished mid-boot — a teardown removed it out from" >&2
  echo "  under this boot. Nothing persisted; just run: frame wt $TOPIC" >&2
  exit 1
fi

# Gitignored assets a fresh worktree lacks — symlink from the primary checkout
# so it boots instantly. Default covers .env (shared server config; exported
# vars still win — dotenvy never overrides the environment) and web/node_modules
# (safe until package.json diverges; npm install manually if it does). Projects
# override with WT_LINKS=(…) in config; entries missing in the primary checkout
# are skipped silently.
if (( ${+WT_LINKS} )); then _links=("${WT_LINKS[@]}"); else _links=(.env web/node_modules); fi
for _l in "${_links[@]}"; do
  if [[ ! -e "$_l" && -e "$MAIN_WT/$_l" ]]; then
    ln -s "$MAIN_WT/$_l" "$_l"
    echo "$OK_MARK symlinked $_l from $MAIN_WT"
  fi
done

# Free ports, scanned upward from the project's primary-env defaults (primary
# on 3000/5173/24678 → first worktree 3001/5174/24679, and so on). Exported
# under the rename-proof FRAME_* names app code should read, plus the
# project-prefixed aliases for code already reading those.
FRAME_VITE_PORT=""
if [[ -n "${API_PORT:-}${VITE_PORT:-}" ]]; then
  export PORT=$(find_free_port "${API_PORT:-3000}")
  FRAME_VITE_PORT=$(find_free_port "${VITE_PORT:-5173}")
  _hmr=$(find_free_port "${HMR_PORT:-24678}")
  export FRAME_API_PORT=$PORT
  export FRAME_HMR_PORT=$_hmr
  export "${PORT_PREFIX}_API_PORT=$PORT"
  export "${PORT_PREFIX}_VITE_PORT=$FRAME_VITE_PORT"
  export "${PORT_PREFIX}_HMR_PORT=$_hmr"
  echo "$OK_MARK worktree env: server :$PORT · vite :$FRAME_VITE_PORT · hmr :$_hmr"
fi

if (( $+functions[app_env] )); then app_env; fi

# Layout parameters — read by layouts/session.lua.
export FRAME_NAME="$NAME"
export FRAME_TOPIC="$TOPIC"
export FRAME_MAIN_WT="$MAIN_WT"
# This frame's own worktree — the branch checkout your work lives in. Pairs with
# FRAME_MAIN_WT (the primary checkout). Exported as a stable anchor so you can
# always cd back here after wandering off; $PWD only equals it at boot. For a
# topicless boot of the primary checkout, PROJECT_DIR == MAIN_WT, so the two
# vars coincide — correct, since there's no separate worktree in that case.
export FRAME_WT="$PROJECT_DIR"
export FRAME_VITE_PORT
export FRAME_BUFFERS="${BUFFERS[*]}"
# Sniff the committed claude hooks this frame is about to boot on. A worktree
# inherits whatever .claude/settings.json the branch carries, so a file that's
# missing or drifted from frame's canonical hook set (frame_claude_hooks_missing
# — the same list init checks and shell re-syncs) silently breaks THIS frame's
# notifications: the exact bite this guards. We only flag it (never rewrite — a
# tracked file, and a blind overwrite could clobber custom hooks). The drift
# list rides along to the layout, which re-emits it via vim.notify so it lands
# in the message area instead of scrolling away under the exec into nvim.
# `frame init --force` re-syncs it (or scaffolds one when the file is absent).
_hook_drift=(${(f)"$(frame_claude_hooks_missing .claude/settings.json)"})
export FRAME_HOOK_DRIFT="${(j:, :)_hook_drift}"
# Config vars referenced by buffers.json are exported under their own names,
# so the registry reads exactly like the config. FRAME_* stays reserved for
# frame-computed values with no config counterpart.
export SERVER_CMD="${SERVER_CMD:-}"
# Where the vite buffer runs `npm run dev`. Defaults to the classic web/
# subdir; root-dir npm apps (e.g. an Astro site) set VITE_DIR=. in config.sh.
export VITE_DIR="${VITE_DIR:-web}"
# NOT `export PORT_PREFIX`: exported, it leaks into every process this frame
# spawns, and a frame_load_config run in there (frame wt/spawn for another
# project) would inherit THIS project's prefix instead of deriving its own —
# same leak spawn.sh guards against with `unset NAME`. The layout's view row
# reads the frame-computed copy instead.
export FRAME_PORT_PREFIX="$PORT_PREFIX"
frame_export_claude_flags
# Carry a warm session in: boot this frame's claude as `claude --resume <id>`
# (from --resume/--from above). Appended after frame_export_claude_flags so it
# composes with the yolo flag. FRAME_CLAUDE_FLAGS is word-split unquoted by the
# claude buffer, and RESUME_ID is validated to the UUID charset, so a plain
# space-join is safe.
if [[ -n "$RESUME_ID" ]]; then
  export FRAME_CLAUDE_FLAGS="${FRAME_CLAUDE_FLAGS:+$FRAME_CLAUDE_FLAGS }--resume $RESUME_ID"
  # `claude --resume` only finds sessions under THIS cwd's project dir, so a
  # session recorded in another worktree (the --from case, or a cross-project
  # --resume) must be bridged into this frame's project dir first — else claude
  # boots "No conversation found". PROJECT_DIR is this frame's claude cwd.
  if ! frame_bridge_transcript "$RESUME_ID" "$PROJECT_DIR"; then
    echo "$WARN_MARK no transcript for session $RESUME_ID under ~/.claude/projects —" >&2
    echo "  claude may boot with 'No conversation found'. The source may never have" >&2
    echo "  started a session, or its transcript was pruned." >&2
  fi
fi

# Refuse before exec if a boot-critical dependency is missing (see frame_require).
# git/nvim always; claude only when this project's frames actually open a claude
# buffer. Terminal mismatch is a soft warning, not a refusal.
frame_check_terminal
_req=(zsh git nvim)
[[ " $FRAME_BUFFERS " == *" claude "* ]] && _req+=(claude)
frame_require "$_req[@]"

exec nvim -S "$FRAME_ROOT/layouts/session.lua"
