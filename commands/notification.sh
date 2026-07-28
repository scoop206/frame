# frame notification — the human-facing banner controls:
#
#   frame notification off | on
#     → the global banner switch: off silences every frame's banners
#       until on
#   frame notification init
#     → (re)build the banner app — badge setup/repair (notifier.sh)
#
# The banner itself is `frame notify` (notify.sh) — the hook target, kept
# argument-free so the controls can't collide with it. The switch is the
# `notify` key of the machine-global config (frame_global_get/set —
# helpers.sh), which notify.sh reads before bannering.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

# init = the banner-app build/repair, exposed where a user hunting for it
# looks. exec: notifier.sh runs as its own process (as init.sh runs it)
# and its exit code and hints pass through untouched.
if (( $# == 1 )) && [[ "$1" == init ]]; then
  exec "$FRAME_ROOT/bin/frame" notifier
fi
if (( $# == 1 )) && [[ "$1" == (on|off) ]]; then
  frame_global_set notify "$1"
  if [[ "$1" == off ]]; then
    echo "$OK_MARK banners off everywhere — frame notification on re-enables"
  else
    echo "$OK_MARK banners on everywhere"
  fi
  exit 0
fi
echo "$X_MARK usage: frame notification on|off|init" >&2
exit 2
