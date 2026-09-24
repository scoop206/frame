# frame kv — layered settings that tell a frame's claude how far to carry its
# work on its own (commit, merge, push, deploy). The keys and their meanings
# live in $FRAME_ROOT/kv.defaults.
#
#   frame kv                                   list every key: value + the layer it came from
#   frame kv get KEY                           print KEY's effective value
#   frame kv set [--project|--user] KEY VALUE  set KEY (default: this frame only)
#   frame kv unset [--project|--user] KEY      drop KEY from that layer, so the
#                                              next layer down shows through
#
# Layers, first hit wins: frame → project → user → default (see the kv section
# of lib/helpers.sh for where each lives). Files, not env vars, so a change
# reaches a running claude — it reads `frame kv get` when it acts.
#
# Settings are the human's. From inside claude (CLAUDECODE set) `set` is
# refused except to false — an agent may rein itself in, never grant itself
# more — and `unset` is refused outright (it could expose a looser layer).
# That's a guard against well-meaning drift, not a security boundary.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

_kv_usage() {
  print -r -- "Usage: frame kv [get KEY | set [--project|--user] KEY VALUE | unset [--project|--user] KEY]" >&2
  exit 2
}

_kv_check_key() {
  if [[ -z "$1" ]] || ! (( ${${(f)"$(frame_kv_keys)"}[(Ie)$1]} )); then
    print -r -- "$X_MARK unknown key '$1' — known: ${(j:, :)${(f)"$(frame_kv_keys)"}}" >&2
    exit 2
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
    typeset -a _keys
    _keys=(${(f)"$(frame_kv_keys)"})
    printf '%-18s %-7s %s\n' KEY VALUE FROM
    for k in $_keys; do
      frame_kv_lookup "$k" || true
      printf '%-18s %-7s %s\n' "$k" "$KV_VALUE" "$KV_LAYER"
    done
    ;;

  get)
    (( $# == 1 )) || _kv_usage
    _kv_check_key "$1"
    frame_kv_get "$1" || true
    ;;

  set)
    (( $# == 2 )) || _kv_usage
    key=$1 val=$2
    _kv_check_key "$key"
    # Boolean keys take only true/false — a "yes" would read as false.
    if [[ "$(frame_kvfile_get "$FRAME_KV_DEFAULTS" "$key")" == (true|false) \
          && "$val" != (true|false) ]]; then
      print -r -- "$X_MARK $key takes true or false, not '$val'" >&2
      exit 2
    fi
    if [[ -n "${CLAUDECODE:-}" && "$val" != false ]]; then
      print -r -- "$X_MARK frame kv settings are the human's — an agent may only set them to false." >&2
      print -r -- "  Ask them to run:  frame kv set${${layer:#frame}:+ --$layer} $key $val   (or :FrameKvSet in nvim)" >&2
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
    _kv_check_key "$key"
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
