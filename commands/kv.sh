# frame kv — layered settings that tell a frame's claude how far to carry its
# work on its own (commit, merge, push, deploy), plus any keys a project or user
# declares for itself. Built-in keys and their meanings live in
# $FRAME_ROOT/kv.defaults; custom ones in <primary checkout>/.frame/kv.defaults
# (committed) or ~/.config/frame/kv.defaults — same format.
#
#   frame kv                                   list every key: value + the layer it came from
#   frame kv get KEY                           print KEY's effective value
#   frame kv set [--project|--user] KEY VALUE  set KEY (default: this frame only)
#   frame kv unset [--project|--user] KEY      drop KEY from that layer, so the
#                                              next layer down shows through
#   frame kv describe [KEY]                    what KEY means, its type, default,
#                                              and where it's declared (all keys
#                                              when bare)
#
# Layers, first hit wins: frame → project → user → default (see the kv section
# of lib/helpers.sh for where each lives). Files, not env vars, so a change
# reaches a running claude — it reads `frame kv get` when it acts.
#
# Settings are the human's. From inside claude (CLAUDECODE set) an agent writes
# only its own frame's layer — never --project/--user — and for a DECLARED key
# only to set a boolean to false: it may rein itself in, never grant itself
# more; string keys can't be set at all (no "safer" direction), and `unset` is
# refused (it could expose a looser layer). Keys nobody declared are the
# agent's own notes (ticket=ENG-412): it may set and unset those freely, on its
# frame only, kept apart from the settings (see lib/helpers.sh). That's a guard
# against well-meaning drift, not a security boundary.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

_kv_usage() {
  print -r -- "Usage: frame kv [get KEY | set [--project|--user] KEY VALUE | unset [--project|--user] KEY | describe [KEY]]" >&2
  exit 2
}

_kv_is_note() {
  # An agent note: undeclared, and present in this frame's agent file.
  ! frame_kv_is_declared "$1" && (( ${${(f)"$(frame_kv_agent_keys)"}[(Ie)$1]} ))
}

_kv_check_key() {
  # Declared keys and existing agent notes pass; anything else is a typo or a
  # key that needs declaring.
  [[ -n "$1" ]] && { frame_kv_is_declared "$1" || _kv_is_note "$1"; } && return 0
  print -r -- "$X_MARK unknown key '$1' — known: ${(j:, :)FRAME_KV_KEYS}" >&2
  if [[ -n "${CLAUDECODE:-}" ]]; then
    print -r -- "  No note by that name on this frame. To keep one: frame kv set $1 VALUE" >&2
  else
    print -r -- "  To add your own, declare it in .frame/kv.defaults (project, committed) or" >&2
    print -r -- "  ~/.config/frame/kv.defaults (user) — same format as frame's kv.defaults." >&2
  fi
  exit 2
}

_kv_agent_frame_only() {
  # An agent writes only its own frame.
  [[ -n "${CLAUDECODE:-}" && "$layer" != frame ]] || return 0
  print -r -- "$X_MARK an agent can only write its own frame's kv, not the $layer layer —" >&2
  print -r -- "  that would reach every frame${${layer:#user}:+ of this project}${${layer:#project}:+ on this machine}." >&2
  print -r -- "  Ask the human to run:  frame kv ${sub} --$layer ${(j: :)${(q-)@}}" >&2
  exit 1
}

_kv_note_file() {
  # The agent-note file for this frame, or exit with why there's none.
  if [[ -z "$FRAME_KV_AGENT_FILE" ]]; then
    print -r -- "$X_MARK not inside a frame — agent notes live on a frame" >&2
    exit 1
  fi
  print -r -- "$FRAME_KV_AGENT_FILE"
}

_kv_warn_decls() {
  # Declaration clashes / malformed lines — shown where the human looks
  # (list, describe, set), not on every get.
  local _w
  for _w in $FRAME_KV_WARNINGS; do
    print -r -- "$WARN_MARK $_w" >&2
  done
}

_kv_describe_one() {
  if ! frame_kv_is_declared "$1"; then
    frame_kv_lookup "$1" || true
    print -r -- "$1 = $KV_VALUE  from $KV_LAYER"
    print -r -- "  agent note: undeclared, kept by this frame's claude; gone at frame wt -d"
    return 0
  fi
  local _k=$1 _type=string _from=${FRAME_KV_FROM[$1]}
  frame_kv_is_bool "$_k" && _type=boolean
  case "$_from" in
    builtin) _from=built-in ;;
    project) _from="project (${FRAME_KV_DECL_FILE[project]})" ;;
    user)    _from="user (${FRAME_KV_DECL_FILE[user]})" ;;
  esac
  frame_kv_lookup "$_k" || true
  print -r -- "$_k = $KV_VALUE  from $KV_LAYER"
  print -r -- "  $_type, default ${FRAME_KV_DEF[$_k]:-<empty>}, declared $_from"
  if [[ -n "${FRAME_KV_DESC[$_k]}" ]]; then
    print -rl -- "  "${^${(f)FRAME_KV_DESC[$_k]}}
  fi
}

_kv_where() {
  # _kv_where LAYER — the file that layer writes to, or exit with why there's none.
  local _file=${FRAME_KV_FILE[$1]:-}
  if [[ -z "$_file" ]]; then
    case "$1" in
      frame)   print -r -- "$X_MARK not inside a frame — use --project or --user" >&2 ;;
      project) print -r -- "$X_MARK not inside a project checkout — use --user" >&2 ;;
    esac
    exit 1
  fi
  print -r -- "$_file"
}

frame_kv_scope_self

sub=${1:-}
(( $# )) && shift

# Scope flag for set/unset; the frame layer is the default target.
layer=frame
if [[ "$sub" == (set|unset) ]]; then
  case "${1:-}" in
    --frame)   layer=frame;   shift ;;
    --project) layer=project; shift ;;
    --user)    layer=user;    shift ;;
    -*)        _kv_usage ;;
  esac
fi

case "$sub" in
  ""|list)
    (( $# == 0 )) || _kv_usage
    _kv_warn_decls
    # Columns fit the longest key/value; a long string value is clipped (see
    # `frame kv get` / `describe` for the whole thing).
    for k in ${(f)"$(frame_kv_agent_keys --shadowed)"}; do
      print -r -- "$WARN_MARK agent note '$k' is ignored — $k is now a declared key" >&2
    done
    typeset -A _vals _from
    typeset -a _all
    _all=($FRAME_KV_KEYS ${(f)"$(frame_kv_agent_keys)"})
    integer _kw=17 _vw=7
    for k in $_all; do
      frame_kv_lookup "$k" || true
      _v=$KV_VALUE
      (( $#_v > 30 )) && _v="${_v[1,29]}…"
      _vals[$k]=$_v _from[$k]=$KV_LAYER
      (( $#k > _kw )) && _kw=$#k
      (( $#_v > _vw )) && _vw=$#_v
    done
    printf "%-${_kw}s %-${_vw}s %s\n" KEY VALUE FROM
    for k in $_all; do
      printf "%-${_kw}s %-${_vw}s %s\n" "$k" "$_vals[$k]" "$_from[$k]"
    done
    ;;

  describe)
    (( $# <= 1 )) || _kv_usage
    _kv_warn_decls
    if (( $# )); then
      _kv_check_key "$1"
      _kv_describe_one "$1"
    else
      _first=1
      for k in $FRAME_KV_KEYS ${(f)"$(frame_kv_agent_keys)"}; do
        (( _first )) || print
        _first=0
        _kv_describe_one "$k"
      done
    fi
    ;;

  get)
    (( $# == 1 )) || _kv_usage
    _kv_check_key "$1"
    frame_kv_get "$1" || true
    ;;

  set)
    (( $# == 2 )) || _kv_usage
    key=$1 val=$2
    _kv_agent_frame_only "$key" "$val"
    if [[ "$val" == *$'\n'* ]]; then
      print -r -- "$X_MARK $key takes a single-line value" >&2
      exit 2
    fi
    # Undeclared key: an agent note. The agent may create one; a human may only
    # edit one that exists (anything else is likelier a typo of a setting).
    if ! frame_kv_is_declared "$key" && [[ "$layer" == frame ]] \
        && { [[ -n "${CLAUDECODE:-}" ]] || _kv_is_note "$key"; }; then
      if ! frame_kv_valid_key "$key"; then
        print -r -- "$X_MARK '$key' isn't a key name — lowercase letters, digits, _; starting with a letter" >&2
        exit 2
      fi
      file=$(_kv_note_file)
      frame_kvfile_set "$file" "$key" "$val" "# frame kv — agent notes for this frame (undeclared keys; see \`frame kv\`)."
      print -r -- "$OK_MARK $key=$val (frame, agent note)"
      exit 0
    fi
    _kv_check_key "$key"
    if ! frame_kv_is_declared "$key"; then
      print -r -- "$X_MARK $key is an agent note — notes live on the frame layer only" >&2
      exit 2
    fi
    _kv_warn_decls
    # Boolean keys take only true/false — a "yes" would read as false. A string
    # takes anything that fits on one line of a key=value file.
    if frame_kv_is_bool "$key"; then
      if [[ "$val" != (true|false) ]]; then
        print -r -- "$X_MARK $key takes true or false, not '$val'" >&2
        exit 2
      fi
    fi
    if [[ -n "${CLAUDECODE:-}" ]] && { ! frame_kv_is_bool "$key" || [[ "$val" != false ]]; }; then
      if frame_kv_is_bool "$key"; then
        print -r -- "$X_MARK frame kv settings are the human's — an agent may only set them to false." >&2
      else
        print -r -- "$X_MARK frame kv settings are the human's — an agent can't set a string key." >&2
      fi
      print -r -- "  Ask them to run:  frame kv set${${layer:#frame}:+ --$layer} $key ${(q-)val}   (or :FrameKvSet in nvim)" >&2
      exit 1
    fi
    file=$(_kv_where "$layer")
    frame_kvfile_set "$file" "$key" "$val" "# frame kv — $layer layer (key=value; see \`frame kv\`)."
    print -r -- "$OK_MARK $key=$val ($layer)"
    frame_kv_lookup "$key" || true
    if [[ "$KV_LAYER" != "$layer" ]]; then
      print -r -- "$WARN_MARK but the $KV_LAYER layer wins: $key=$KV_VALUE — unset it there to let this show"
    fi
    ;;

  unset)
    (( $# == 1 )) || _kv_usage
    key=$1
    _kv_agent_frame_only "$key"
    _kv_check_key "$key"
    if _kv_is_note "$key"; then
      if [[ "$layer" != frame ]]; then
        print -r -- "$key is an agent note on this frame, not set in the $layer layer — nothing to unset"
        exit 0
      fi
      frame_kvfile_unset "$(_kv_note_file)" "$key"
      print -r -- "$OK_MARK unset $key (frame, agent note)"
      exit 0
    fi
    if [[ -n "${CLAUDECODE:-}" ]]; then
      print -r -- "$X_MARK frame kv settings are the human's — an agent can't unset them" >&2
      print -r -- "  (that could expose a looser layer). Set it to false instead." >&2
      exit 1
    fi
    file=$(_kv_where "$layer")
    if frame_kvfile_unset "$file" "$key"; then
      frame_kv_lookup "$key" || true
      print -r -- "$OK_MARK unset $key ($layer) — now $key=${KV_VALUE:-<unset>}${KV_LAYER:+ from $KV_LAYER}"
    else
      print -r -- "$key isn't set in the $layer layer — nothing to unset"
    fi
    ;;

  *)
    _kv_usage
    ;;
esac
