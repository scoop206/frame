# Scratch git fixtures, all inside $SANDBOX. Origin is a local bare repo —
# push/fetch/clone never leave the sandbox.

make_repo() {
  # make_repo [name] — bare origin + working repo with one pushed commit on
  # main. cds into the repo and sets $REPO. Default name is $TNAME so frame's
  # NAME defaults line up and $FRAME_RUNDIR/<NAME>-* paths stay unique per test.
  local name=${1:-$TNAME}
  git init -q --bare "$SANDBOX/origin.git"
  git init -q "$SANDBOX/$name"
  REPO="$SANDBOX/$name"
  cd "$REPO"
  print -r -- "# $name" > README.md
  git add README.md
  git commit -qm "initial commit"
  git remote add origin "$SANDBOX/origin.git"
  git push -qu origin main 2>/dev/null
}

make_topic() {
  # make_topic TOPIC — branch + worktree at $SANDBOX/_$TNAME-TOPIC (frame's
  # naming convention) with one commit.
  local topic=$1
  git -C "$REPO" worktree add -q "$SANDBOX/_$TNAME-$topic" -b "$topic"
  commit_file "$SANDBOX/_$TNAME-$topic" "$topic.txt" "work on $topic"
}

write_config() {
  # write_config [repo] <<'EOF' … EOF — writes .frame/config.sh (untracked;
  # frame_load_config finds it regardless, and worktrees fall back to it).
  local repo=${1:-$REPO}
  mkdir -p "$repo/.frame"
  cat > "$repo/.frame/config.sh"
}

write_local_config() {
  local repo=${1:-$REPO}
  mkdir -p "$repo/.frame/local"
  cat > "$repo/.frame/local/config.sh"
}

commit_file() {
  # commit_file REPO PATH [CONTENT] [MSG]
  # nb: the variable must not be called `path` — zsh ties that to $PATH.
  local repo=$1 file=$2 content=${3:-content} msg=${4:-"add $2"}
  mkdir -p "$repo/${file:h}"
  print -r -- "$content" > "$repo/$file"
  git -C "$repo" add "$file"
  git -C "$repo" commit -qm "$msg"
}
