# frame

[![tests](https://github.com/scoop206/frame/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/scoop206/frame/actions/workflows/test.yml)

An opinionated AI harness built around **neovim** and **git worktrees** — a frame
per feature, parallel Claude sessions you can tell apart, and shared services
across all your projects.

<p align="center">
  <img src="assets/frame-icon.png" alt="frame icon: a stack of overlapping windows" width="216">
</p>

<!-- Record with: vhs assets/demo.tape  (see assets/demo.tape) -->
<p align="center">
  <img src="assets/demo.gif" alt="frame wt booting a worktree into neovim with a Claude buffer" width="900">
</p>

## Table of Contents

- [What Frame does](#what-frame-does)
- [Features](#features)
- [Installation](#installation)
  - [Prerequisites](#prerequisites)
  - [Install Frame](#install-frame)
  - [Recommended extras](#recommended-extras)
- [Getting Started](#getting-started)
- [Concepts: Frames](#concepts-frames)
- [Vim commands](#vim-commands)
- [Frame Merge](#frame-merge)
- [Frame Removal](#frame-removal)
- [Notifications](#notifications)
- [How a project plugs in](#how-a-project-plugs-in)
- [Buffer Definitions](#buffer-definitions)
- [Shared (Centralized) Services](#shared-centralized-services)
- [License](#license)

## What Frame does

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
frame focus [TOPIC|NAME/TOPIC]  raise that frame's ghostty window (default: the one you're in)
```

`worktree` is accepted as a synonym for `wt`.

## Features

- A frame per feature
- Parallel sessions you can tell apart
- Claude notifications
- Shared postgres + minio (or whatever) across all your projects
- minimal neovim, zsh, git worktrees

## Installation

### Prerequisites

- zsh
- git ≥ 2.5
- neovim (no plugins required)
- claude (Claude Code CLI) — permission prompts stay on unless you opt in with `frame yolo on`
- docker with the compose v2 plugin
- macOS + OrbStack (any docker provider works if already running; auto-start is OrbStack-only)
- curl, lsof

Frame also assumes **every project's default branch is named `main`**.

### Install Frame

```bash
# 1. Clone Frame — location doesn't matter
git clone https://github.com/scoop206/frame.git
cd frame

# 2. Put frame on your PATH (this line persists it in ~/.zshrc)
echo "export PATH=\"$PWD/bin:\$PATH\"" >> ~/.zshrc
exec zsh

# 3. Verify
frame --help
```

### Recommended extras

- **Ghostty** — the terminal Frame was built with; on others your YMMV.
- **Raycast** — window fuzzy-find lets you leverage the WAITING and TOPIC name of your frames.
- **homebrew + terminal-notifier** — optional; `brew install terminal-notifier`,
  then `frame notification init` (or the first `frame init`) builds the frame-icon,
  click-to-focus banner app (without them, plain osascript banners still fire).

## Getting Started

From inside any project, scaffold its Frame config and start a worktree:

```bash
cd your-project

# 1. Scaffold .frame/config.sh and gitignore .frame/local/
frame init

# 2. (optional) let Claude run with permissions skipped in every frame
frame yolo on

# 3. Create a topic worktree and boot it
frame wt scratch-topic
```

Neovim will fire up with the Claude buffer in the foreground.

A bare-bones `.frame/config.sh` needs only your buffer list — if you'd rather write
it by hand instead of running `frame init`:

```bash
cd your-project && mkdir -p .frame && echo "BUFFERS(claude local)" > .frame/config.sh
```

See [How a project plugs in](#how-a-project-plugs-in) for the full config.

## Concepts: Frames

A frame is a terminal window running neovim as its buffer management layer (multiplexer).
This is usually one buffer running Claude and then whatever else is appropriate.
Frames assumes a 1:1:1 mapping between a frame:worktree:branch.

All work happens in topic worktrees, each a self-sufficient peer — `frame wt` runs the
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

The ghostty window will now be named `$REPO [ $TOPIC :PORT ]`
You can see vite's rendered web app at http://localhost:PORT

## Vim commands

When frame instantiates the nvim instance it injects these user commands
(defined in `layouts/worktree.lua`), available from any buffer in the session:

| command              | action                                                                        |
| -------------------- | ----------------------------------------------------------------------------- |
| `:FrameStatus TEXT…` | append "- TEXT" to the window title's status suffix (no TEXT clears it)       |
| `:FrameNotify off`   | 'on' or 'off' to unmute/mute banners; no arg shows state                      |
| `:FrameQuit`         | quit the session only — worktree and branch stay for a later `frame wt TOPIC` |
| `:FrameDown`         | tear down the whole frame: quit nvim, remove the worktree, delete the branch  |
| `:FrameDown!`        | force teardown — discard uncommitted changes and unmerged commits             |

## Frame Merge

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

## Frame Removal

Tear down from _inside_ the frame — either entry point works:

- in nvim: `:FrameDown`
- in any terminal buffer: `frame wt -d`

From outside the frame — the project's primary checkout, or another frame of
the same project: `frame wt -d TOPIC`. TOPIC is resolved in the current
project's namespace, so you must run it from inside that project's git tree.

### Teardown Safeguards

Teardown refuses if the worktree has uncommitted changes or the branch has
commits not yet on main — merge first (`frame merge`), or force with
`frame wt -d -f [TOPIC]` / `:FrameDown!`. These checks run _before_ nvim is
quit, so a refusal never leaves you editor-less. Reaper output lands in
`/tmp/<name>-<topic>.teardown.log`.

## Notifications

### Fixing the banner badge

At first the badge is a generic AppleScript badge — clicking it opens Script
Editor instead of focusing your frame. Things work fine in this state, but here
are the extra steps to get the badge right:

```bash
brew install terminal-notifier
```

Then build the Frame app icon for the banner with:

```bash
frame notification init
```

You should be prompted to allow for Frame to notify:

- System Settings → Notifications → Frame → Allow.

You can send a test notification with:

```bash
frame notify
```

If the new badge is still not working you can also try (they will respawn):

```
killall usernoted NotificationCenter
```

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

Within the Frame repo is `services/docker-compose.yml`. Helper functions in
`lib/helpers.sh` create roles/databases/buckets idempotently.

## License

[MIT](LICENSE)
