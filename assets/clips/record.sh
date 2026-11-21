#!/usr/bin/env zsh
# record.sh TAPE — run vhs on a landing-page tape inside the demo sandbox
# (see make-demo-home.sh). The env is wiped so nothing from the frame you run
# it from leaks in: inherited FRAME_*/NVIM vars make frame refuse a "nested"
# boot. Run from the repo root; the tapes write to site/clips/.
emulate -L zsh
set -euo pipefail
H=${DEMO_HOME:-/Users/Shared/frame-demo}
[[ -d "$H/.claude/projects" ]] || { print -u2 "✗ no demo home at $H — run assets/clips/make-demo-home.sh"; exit 1; }
root=${0:A:h:h:h}
# where the tools live on this machine (claude, vhs, nvim, fzf, jq), deduped
typeset -U dirs=()
for t in claude vhs nvim fzf jq ttyd ffmpeg; do (( $+commands[$t] )) && dirs+=(${commands[$t]:h}); done
tooldirs=${(j.:.)dirs}
# TERM_PROGRAM=ghostty below only quiets frame's "not in Ghostty" boot warning;
# the clips never use focus/spawn, the parts that need real Ghostty.
# reset the demo repos: an earlier take may have let claude edit them
for r in $H/code/*(N/); do git -C $r checkout -q . ; done
exec env -i HOME=$H USER=$USER LOGNAME=$USER SHELL=/bin/zsh TERM=xterm-256color \
  LANG=${LANG:-en_US.UTF-8} TZ=${TZ:-$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')} \
  TERM_PROGRAM=ghostty \
  PATH="$root/bin:$tooldirs:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  vhs "$@"
