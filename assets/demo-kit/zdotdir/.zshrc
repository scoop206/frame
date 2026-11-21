# The demo kit's recording shell (see ../demo). Clean prompt, `#` comments
# allowed, and the scene's commands pre-typed: the first one is on the line at
# start, Ctrl-N types the next.
setopt interactive_comments no_beep
PROMPT='%F{208}❯%f '
RPROMPT=''
HISTFILE=/dev/null
cd "${DEMO_CWD:-$HOME}"

typeset -ga DEMO_CMDS=( ${(f)"$(cat $DEMO_CUES 2>/dev/null)"} )
typeset -gi DEMO_NEXT=2
demo-next() {
  (( DEMO_NEXT <= $#DEMO_CMDS )) || { zle -M "no more cues"; return; }
  BUFFER=$DEMO_CMDS[DEMO_NEXT]; CURSOR=$#BUFFER
  (( DEMO_NEXT++ ))
}
zle -N demo-next
bindkey '^N' demo-next
(( $#DEMO_CMDS )) && print -z -- "$DEMO_CMDS[1]"
