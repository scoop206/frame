# frame

[![tests](https://github.com/scoop206/frame/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/scoop206/frame/actions/workflows/test.yml)

An opinionated AI harness based around:

- neovim
- git worktrees

<p align="center">
  <img src="assets/frame-icon.png" alt="frame icon: a stack of overlapping windows" width="216">
</p>

Run from a project:

```
frame init                 scaffold .frame/config.sh, gitignore .frame/local/;
                           first init also builds the banner app (frame icon +
                           click-to-focus banners)
frame wt TOPIC             create/reuse branch TOPIC + worktree ../_<name>-TOPIC, boot it
frame wt                   boot the worktree you're already in
frame wt -d [-f] [TOPIC]   tear down a frame (defaults to the one you're in)
frame shell TOPIC          casual frame in ~/frames/TOPIC — no repo, no branch,
                           just the claude + local buffers
frame merge [TOPIC] [--push|--ff|-n]   merge into main from the primary worktree
frame services [up|down|ps]            manage the shared postgres/minio stack
frame status [TEXT…]       append "- TEXT" to this frame's window title (no TEXT clears)
frame notify               frame will send waiting notification
frame notification on|off|init   on|off: global switch
                           init: build/repair the banner app (needs `brew install terminal-notifier`)
frame yolo on|off          master switch: claude in every frame launches with
                           --dangerously-skip-permissions (default off)
frame focus [NAME/TOPIC]   raise that frame's ghostty window (default: the one you're in)
```

`worktree` is accepted as a synonym for `wt`.

### Features

- A frame per feature
- Parallel sessions you can tell apart
- Claude notifications
- Shared postgres + minio (or whatver) across all your projects
- stock neovim (no plugins), zsh, git worktrees

### Frames

A frame is a terminal window running neovim as it's buffer management layer (multiplexer).
This is usually one buffer running Claude and then whatver else is appropriate.
Frames assumes a 1:1:1 mapping between a frame:worktree:branch.

All work happens in topic worktrees, each are self-sufficient peer — `frame wt` runs the
project's idempotent `stack_up()`, so whichever frame boots first brings up
the shared services.

Worktrees are created beside the primary checkout as `../_<name>-<topic>`.
The leading underscore marks them as frame-managed and keeps them sorted
together in the parent directory; frame also parses the name to infer the
topic when you run `frame wt` (or `frame wt -d`) from inside one.

`frame wt TOPIC` is the typical entrypoint.

For example:
This starts neovim w/ custom layout which is usually 4 buffers:

- claude - starts claude-code
- vite - cd web && npm run dev
- server - cargo run -p $PROJECT-server
- local - bare terminal

The ghostty window will now be named $REPO/$TOPIC:PORT
You can see vite's rendered web app at http://localhost:PORT

### Vim commands

When frame instantiates the nvim instance it injects these user commands
(defined in `layouts/worktree.lua`), available from any buffer in the session:

| command              | action                                                                        |
| -------------------- | ----------------------------------------------------------------------------- |
| `:FrameStatus TEXT…` | append "- TEXT" to the window title's status suffix (no TEXT clears it)       |
| `:FrameNotify off`   | 'on' or 'off' to umute/mute banners; no arg shows state)                      |
| `:FrameQuit`         | quit the session only — worktree and branch stay for a later `frame wt TOPIC` |
| `:FrameDown`         | tear down the whole frame: quit nvim, remove the worktree, delete the branch  |
| `:FrameDown!`        | force teardown — discard uncommitted changes and unmerged commits             |

In a casual frame (`frame shell`) `:FrameDown!` quits and deletes the topic
directory; plain `:FrameDown` always refuses, since nothing there is under git.

### Notifications

#### Fixing the banner badge

At first the badge is a generic AppleScript badge — clicking it opens Script
Editor instead of focusing your frame.

Things work fine in this state but here's extra to steps to get the badge right:

`brew install terminal-notifier`  
`

To fix:

- System Settings → Notifications → Frame → Allow.
- Clicking a badge also asks for Accessibility on the first click; grant that
  too. Both are one-time.

Fire a test banner with `frame notify` to check any fix.

**If banners lose the badge later** (generic or Terminal icon instead of the
frame vortex):

1. `killall usernoted NotificationCenter` — both notification daemons cache the
   old icon; they respawn instantly, and a stale cache is the usual culprit.
2. Still wrong? Force a rebuild: `rm -rf ~/.local/share/frame/Frame.app`,
   then `frame notification init`. The rebuild mints a fresh code signature, and
   macOS keys the notification grant to the signature — so re-allow the
   banners in System Settings → Notifications → Frame afterwards.

### Frame Merge

When you are done working on the feature you (or claude) can merge to main —
from wherever you are:

```
frame merge                merge the current worktree's branch
frame merge TOPIC          merge branch TOPIC
frame merge TOPIC --push   …and push main to origin afterward
frame merge --ff           fast-forward instead of a merge commit
frame merge -n             dry run: print the plan, change nothing
```

The worktrees share one object store, so the primary checkout already sees
every topic branch. `frame merge` drives that primary worktree via `git -C`:
fast-forward main to origin, merge the topic branch, and (only when asked)
push — all without leaving whichever worktree you're in.

Safeguards, in the order they run:

- **Primary must be clean** — refuses if the primary worktree has uncommitted
  tracked changes on main.
- **Uncommitted topic work is flagged** — only the committed branch tip gets
  merged, so a warning calls out anything uncommitted in the topic worktree
  that would be silently left out.
- **No guessing on divergence** — main is brought level with origin first
  (fast-forward only); if main and origin have diverged, it stops and leaves
  the reconciliation to you.
- **Conflicts stop cleanly** — on a merge conflict it halts and prints the
  exact `merge --abort` to back out.
- **Push is opt-in** — nothing touches origin unless you pass `--push`.

Worktree and branch cleanup stays with `frame wt -d` (below).

### Frame Removal

Tear down from _inside_ the frame — either entry point works:

- in nvim: `:FrameDown`
- in any terminal buffer: `frame wt -d`

From outside the frame — the project's primary checkout, or another frame of
the same project: `frame wt -d TOPIC`. TOPIC is resolved in the current
project's namespace, so you must run it from inside that project's git tree.

#### Teardown Safeguards

Teardown refuses if the worktree has uncommitted changes or the branch has
commits not yet on main — merge first (`frame merge`), or force with
`frame wt -d -f [TOPIC]` / `:FrameDown!`. These checks run _before_ nvim is
quit, so a refusal never leaves you editor-less. Reaper output lands in
`/tmp/<name>-<topic>.teardown.log`.

### Installation and Getting Started

Clone this repo (location does not matter)  
Check the dependcies (see below).  
put `/path/to/frame/bin/` on your PATH.  
add a .frame directory to your projects. To get a bare bones do:

```
cd project && mkdir -p .frame && echo "BUFFERS(claude local)" > .frame/config.sh
```

Bump up the Claude permissions if you desire: `frame yolo on`

Start a frame worktree instance:

```
cd project
frame wt scratch-topic
```

Neovim will fire up with the Claude buffer in the foreground.

### Dependencies

- zsh
- git ≥ 2.5
- neovim (no plugins required)
- claude (Claude Code CLI) — permission prompts stay on unless you opt in with `frame yolo on`
- docker with the compose v2 plugin
- macOS + OrbStack (any docker provider works if already running; auto-start is OrbStack-only)
- curl, lsof

### Assumptions

- every project's default branch is named `main`

### Recommended

- Ghostty - was the terminal Frame was built with so for others your MMV
- Raycast - window fuzzy find allows you to leverage the WAITING and TOPIC name of your frames
- homebrew + terminal-notifier - optional; `brew install terminal-notifier`,
  then `frame notification init` (or the first `frame init`) builds the frame-icon,
  click-to-focus banner app (without them, plain osascript banners still fire)

## How a project plugs in

Everything project-side lives under one `.frame/` directory:

| path               | committed?         | contents                                                                                                                           |
| ------------------ | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| `.frame/config.sh` | yes                | project facts:<br>`NAME=`<br>`SERVER_CMD=`<br>`API_PORT=` `VITE_PORT=` `HMR_PORT=`<br>`BUFFERS=(…)`<br>`stack_up()`<br>`app_env()` |
| `.frame/local/`    | never (gitignored) | personal overrides — a `config.sh` here wins                                                                                       |

### config.sh

config: `NAME`  
required: yes  
value: the project name; window titles, worktree dirs, and PORT_PREFIX derive from it

config: `BUFFERS(...)`  
required: yes  
value: which buffers this project's frames open, e.g. BUFFERS=(claude local) — see Buffers below

Hooks:

- `stack_up()` — bring up whatever the dev stack needs. Runs on every `frame wt`
  boot, so keep it idempotent. Shared postgres/minio come from
  `frame_services_up` / `ensure_pg_db` / `ensure_minio_bucket`; only
  project-unique containers belong in the project's own compose file — pin
  those with `--project-directory "$MAIN_WT"` so every frame shares one
  instance instead of spawning a per-worktree compose project.
- `app_env()` — export the vars pointing the app at what Frame set up: the
  shared services (`DATABASE_URL`, S3 endpoint, …) and, if your app reads its
  port under a name other than the `PORT` frame tracks (see `buffers.json`),
  a re-export of it here (e.g. `export SERVICE_PORT="$PORT"`). Exported vars
  win over `.env` (dotenvy never overrides the environment).

## Buffer Definitions

Every buffer type a project can instantiate needs to be in the `buffers.json` Frame registry.

Per entry:

| field   | meaning                                                                    |
| ------- | -------------------------------------------------------------------------- |
| name    | buffer name (targeted by `BUFFERS`)                                        |
| mode    | `durable` auto-runs and drops to a shell on exit; `bare` is an empty shell |
| command | the command the buffer runs                                                |
| dir     | subdirectory to run in                                                     |
| env     | vars the command reads — a declared contract; frame warns at boot if unset |
| focus   | land here after boot                                                       |

## Shared (Centralized) Services

Within Frame repo is services/docker-compose.yml  
Helper functions in
`lib/helpers.sh` create roles/databases/buckets idempotently.

## License

[MIT](LICENSE)
