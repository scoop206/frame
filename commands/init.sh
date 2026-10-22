# frame init — scaffold a project's .frame/ directory:
#   .frame/config.sh   committed project facts, from the chosen types
#   .frame/local/      personal overrides + state — appended to .gitignore
#
# --type TYPE (repeatable) picks what goes in. A project has one BASE (default
# generic) plus any number of LAYERS. A type is a folder of plain files — no
# code runs at init:
#   type             kind=base|layer and a one-line description=
#   config.sh        base: the whole config.sh ({{NAME}} → the project name)
#   config.layer.sh  layer: lines appended to config.sh (once — skipped if present)
#   files/           copied into the project root, each only if absent
#   gitignore        lines appended to .gitignore once, under "# frame:TYPE"
# Types are looked up in ~/.config/frame/types/ (yours) first, then frame's
# templates/types/, so yours replaces a built-in of the same name.
# `frame init --types` lists them.
#
# Never overwrites a file. Re-running with a new layer appends its lines to an
# existing config.sh; a new base's config.sh only lands in a fresh project.
# Never stages or commits: `frame wt` only inherits committed files, so when a
# type copied files into a repo, a reminder says to review and commit them.
# No git repo needed: outside one (or under a $HOME dotfiles repo) init
# scaffolds the cwd and skips .gitignore. Refuses ~ itself.
#
# --force is accepted and ignored (it used to re-sync .claude/settings.json;
# claude's hooks now come from frame itself). --type shell is a no-op notice.
#
# Exit status: 0 ok; 1 = run in ~ itself; 2 = usage error.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

_user_types="${XDG_CONFIG_HOME:-$HOME/.config}/frame/types"
_builtin_types="$FRAME_ROOT/templates/types"

# _type_dir NAME — print the folder for type NAME (yours first), or fail.
_type_dir() {
  local _d
  for _d in "$_user_types/$1" "$_builtin_types/$1"; do
    [[ -f "$_d/type" ]] && { print -r -- "$_d"; return 0; }
  done
  return 1
}

# _type_get DIR KEY — a key=value from DIR/type, read as text (never sourced).
_type_get() {
  local _line
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ "$_line" == "$2="* ]] && { print -r -- "${_line#*=}"; return 0; }
  done < "$1/type"
  return 0
}

_list_types() {
  local -A _seen
  local _root _d _n _src _w=4
  for _d in "$_user_types"/*(N/) "$_builtin_types"/*(N/); do
    [[ -f "$_d/type" ]] && (( ${#${_d:t}} > _w )) && _w=${#${_d:t}}
  done
  for _root in "$_user_types" "$_builtin_types"; do
    for _d in "$_root"/*(N/); do
      [[ -f "$_d/type" ]] || continue
      _n=${_d:t}
      (( ${+_seen[$_n]} )) && continue
      _seen[$_n]=1
      _src=""
      if [[ "$_root" == "$_user_types" ]]; then
        _src="  (yours"
        [[ -f "$_builtin_types/$_n/type" ]] && _src+=" — replaces built-in"
        _src+=")"
      fi
      [[ "$_n" == generic ]] && _src+="  (default)"
      printf '  %-*s  %-5s  %s%s\n' $_w "$_n" "$(_type_get "$_d" kind)" "$(_type_get "$_d" description)" "$_src"
    done
  done
}

typeset -a _types
while (( $# )); do
  case "$1" in
    -f|--force) ;;
    --types) _list_types; exit 0 ;;
    --type)
      shift
      [[ -n "${1:-}" ]] || { echo "$X_MARK frame init: --type needs a value" >&2; exit 2; }
      _types+=("$1") ;;
    --type=*) _types+=("${1#--type=}") ;;
    -*) echo "$X_MARK frame init: unknown flag: $1" >&2; exit 2 ;;
    *)  echo "$X_MARK frame init: unexpected argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# Resolve the types: exactly one base (generic unless one is named), layers in
# the order given.
BASE=generic
_base_set=0
typeset -a _layers
for _t in "${_types[@]}"; do
  if [[ "$_t" == shell ]]; then
    echo "$OK_MARK nothing to do — frame shell -C DIR works on any dir now (claude gets frame's hooks from frame itself)"
    exit 0
  fi
  if [[ "$_t" != [a-z0-9]* || "$_t" == *[^a-z0-9_-]* ]] || ! _d=$(_type_dir "$_t"); then
    echo "$X_MARK frame init: unknown --type '$_t' — see: frame init --types" >&2
    exit 2
  fi
  case "$(_type_get "$_d" kind)" in
    base)
      if (( _base_set )) && [[ "$BASE" != "$_t" ]]; then
        echo "$X_MARK frame init: conflicting base types '$BASE' and '$_t' (a project has one base)" >&2
        exit 2
      fi
      BASE=$_t; _base_set=1 ;;
    layer) (( ${_layers[(Ie)$_t]} )) || _layers+=("$_t") ;;
    *) echo "$X_MARK frame init: type '$_t' has no kind=base|layer in $_d/type" >&2; exit 2 ;;
  esac
done
_base_dir=$(_type_dir "$BASE") || { echo "$X_MARK frame init: base type '$BASE' not found" >&2; exit 2; }
typeset -a _all=("$BASE" "${_layers[@]}")

# Inside a git repo, scaffold at its root. Outside one — or under a $HOME
# dotfiles repo, which is never a frame project — scaffold the cwd as-is and
# skip .gitignore (re-run init after `git init` to add it).
if PROJECT_ROOT=$(frame_project_root); then
  IN_GIT=1
else
  IN_GIT=0
  PROJECT_ROOT=$PWD
  if [[ "${PWD:A}" == "${HOME:A}" ]]; then
    echo "$X_MARK frame init: refusing to scaffold your home dir (~) — cd into a project first" >&2
    exit 1
  fi
fi
cd "$PROJECT_ROOT"
mkdir -p .frame/local

# The project name for {{NAME}}: the primary checkout's dir name in a repo (so
# init from a worktree still names the project), else the cwd's.
if (( IN_GIT )); then _name="${$(frame_main_wt "$PROJECT_ROOT"):t}"; else _name="${PROJECT_ROOT:t}"; fi

# Each block records one "FILE|MODIFIED|NOTE" row; the table prints at the end.
typeset -a _rows

# ── .frame/config.sh: the base's template, then each layer's missing lines ──
_cfg=.frame/config.sh
if [[ -f $_cfg ]]; then
  _fresh=0
else
  _fresh=1
  if [[ -f "$_base_dir/config.sh" ]]; then
    _tpl="$(<"$_base_dir/config.sh")"
    print -r -- "${_tpl//\{\{NAME\}\}/$_name}" > $_cfg
  else
    : > $_cfg
  fi
fi
typeset -a _added_by
for _t in "${_layers[@]}"; do
  _f="$(_type_dir "$_t")/config.layer.sh"
  [[ -f "$_f" ]] || continue
  # Appended whole, unless that exact block is already there (a re-run).
  _blk="$(<"$_f")"
  _blk=${_blk//\{\{NAME\}\}/$_name}
  if [[ "$(<$_cfg)" != *"$_blk"* ]]; then
    print -r -- "$_blk" >> $_cfg
    _added_by+=("$_t")
  fi
done
if (( _fresh )); then
  _rows+=( "$_cfg|yes|scaffolded (${(j:+:)_all}) — edit it to fit the project" )
elif (( ${#_added_by} )); then
  _rows+=( "$_cfg|yes|added ${(j:, :)_added_by} lines" )
else
  _rows+=( "$_cfg|no|already exists — left alone" )
fi

# ── files/: copied into the project root, each only if absent ──
typeset -a _copied_by
for _t in "${_all[@]}"; do
  _d="$(_type_dir "$_t")/files"
  [[ -d "$_d" ]] || continue
  _n=0
  for _src in "$_d"/**/*(.DN); do
    _rel=${_src#$_d/}
    if [[ -e "$_rel" ]]; then
      _rows+=( "$_rel|no|already exists — left alone" )
    else
      mkdir -p "${_rel:h}"
      cp "$_src" "$_rel"
      _rows+=( "$_rel|yes|scaffolded ($_t)" )
      (( ++_n ))
    fi
  done
  (( _n )) && _copied_by+=("$_t")
done

# ── .gitignore: .frame/local/ always, then each type's block once ──
if (( ! IN_GIT )); then
  _rows+=( ".gitignore|no|not a git repo — skipped (re-run init after git init)" )
else
  if [[ -f .gitignore ]] && grep -qxF '.frame/local/' .gitignore; then
    _rows+=( ".gitignore|no|already covers .frame/local/" )
  else
    printf '\n# frame — personal/local harness overrides, never committed\n.frame/local/\n' >> .gitignore
    _rows+=( ".gitignore|yes|added .frame/local/" )
  fi
  for _t in "${_all[@]}"; do
    _f="$(_type_dir "$_t")/gitignore"
    [[ -f "$_f" ]] || continue
    if [[ -f .gitignore ]] && grep -qxF "# frame:$_t" .gitignore; then
      _rows+=( ".gitignore|no|already covers $_t" )
    else
      { printf '\n# frame:%s\n' "$_t"; cat "$_f"; } >> .gitignore
      _rows+=( ".gitignore|yes|added $_t lines" )
    fi
  done
fi

# Print the summary table: widen the FILE column to its longest entry so the
# MODIFIED / NOTE columns line up.
_w=4  # len("FILE")
for _r in $_rows; do
  _f=${_r%%|*}
  (( ${#_f} > _w )) && _w=${#_f}
done
printf '\n  %-*s  %-8s  %s\n' $_w FILE MODIFIED NOTE
for _r in $_rows; do
  _f=${_r%%|*}; _rest=${_r#*|}
  printf '  %-*s  %-8s  %s\n' $_w "$_f" "${_rest%%|*}" "${_rest#*|}"
done

# `frame wt` only hands a worktree the COMMITTED files, so an uncommitted
# scaffold isn't there on the first boot — but init never commits for you.
if (( ${#_copied_by} && IN_GIT )) && [[ -n "$(git status --porcelain)" ]]; then
  print -- "\n  $WARN_MARK the ${(j:+:)_copied_by} scaffold is NOT committed — \`frame wt <topic>\` only"
  print -- "    inherits committed files, so review the scaffold and commit it yourself:"
  print -- "        git add -A && git commit -m 'frame init: scaffold project'"
fi
