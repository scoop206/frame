# frame

[![tests](https://github.com/scoop206/frame/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/scoop206/frame/actions/workflows/test.yml)

frame - an AI harness built on: zsh, ghostty, neovim, and claude code

<p align="center">
  <img src="assets/frame_badge.png" alt="frame badge: three ordered tabs over a window with a neovim-chamfered N on terracotta" width="216">
</p>

<!-- Record with: vhs assets/demo.tape  (see assets/demo.tape) -->
<p align="center">
  <img src="assets/demo.gif" alt="frame wt booting a worktree into neovim with a Claude buffer" width="900">
</p>

## Table of Contents

- [What Frame does](#what-frame-does)
- [Other Features](#other-features)
- [Getting Started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Install Frame](#install-frame)
  - [Onboarding a project](#onboarding-a-project)
- [Worktrees](#worktrees)
- [Vim commands](#vim-commands)
- [Frame Merge](#frame-merge)
- [Frame Removal](#frame-removal)
- [Notifications](#notifications)
- [Swarm: telling agents they're in a frame](#swarm-telling-agents-theyre-in-a-frame)
- [How a project plugs in](#how-a-project-plugs-in)
- [Buffer Definitions](#buffer-definitions)
- [Shared (Centralized) Services](#shared-centralized-services)
- [License](#license)

## What Frame does

- A frame is a terminal running one Neovim instance provisioned with an RPC socket (a named nvim server, so other frames and the CLI can drive it).
- Each frame has one Claude buffer.
- The frame CLI injects lua and puts a message broker in front of claude.
- frames join the pool and become discoverable via `frame ls`
- In addition to claude you will typically have services like Vite and or binary backend service running in their own buffers. Frame manages the port assignments so you can stand up a frame per worktree/Topic.  
  They are self contained and disposable: once a topic is merged (`frame merge`;`:FrameMerge`), tear the frame down (`frame wt -d`;`:FrameDown`). Merge and teardown are separate guarded steps to ensure a clean delivery back to main before frame disassembly.
- Ghostty is the intended terminal — window focus and spawn-into-tabs use its scripting — but a frame still runs in other terminals.

| command                      | what it does                                                                           |
| ---------------------------- | -------------------------------------------------------------------------------------- |
| `frame wt TOPIC`             | create/reuse a branch and worktree, boot it                                            |
| `frame wt`                   | boot the worktree you're already in                                                    |
| `frame wt -d [TOPIC]`        | tear down a frame (default: the current one)                                           |
| `frame shell TOPIC`          | a frame with no repo — just the claude and local buffers                               |
| `frame ls`                   | list every live frame across projects                                                  |
| `frame merge [TOPIC]`        | merge a topic branch into main                                                         |
| `frame claude TEXT…`         | ask this frame's claude, block for the answer                                          |
| `frame req NAME/TOPIC TEXT…` | ask another frame's claude (async)                                                     |
| `frame inbox`                | read replies routed back to you                                                        |
| `frame services up`          | bring up the shared services stack                                                     |
| `frame focus [TOPIC]`        | raise a frame's window                                                                 |
| `frame yolo on\|off`         | toggle `--dangerously-skip-permissions` everywhere                                     |
| `frame swarm [off\|1\|2]`    | how much frame context each frame's claude gets — 0 off · 1 aware · 2 ask (starts off) |

`worktree` is a synonym for `wt`; `list` for `ls`.  
Not shown here: `spawn`,
`deliver`, `reply`, `view`, `status`, `notify`, `notification`, and every
`--flag` — see `frame --help`.

## Other Features

- **Vim/Claude integration** - `:FrameClaude` allows for quick conversations and code analysis
- **Shared Services** - Databases and Object Stores can be stood up once in the frame repo and share their services between all your projects
- OSs level **Notifications** - a from has **Completed** it's task, a frame Needs **Attention**, a frame is **Blocked**.
- **swarm** - uses a SessionStart hook to inform claude about the frame tool and teach it how to self-discover the other frames. It's a dial: level 1 makes a frame aware, level 2 lets it ask siblings read-only questions — but frames should not initiate actions on each other's behalf. See [Swarm: telling agents they're in a frame](#swarm-telling-agents-theyre-in-a-frame) for the per-level breakdown.
- **shell** - a thin (non worktree) frame for raw claude work
- Easily enable/disable **YOLO mode** (--dangerously-skip-permissions)

## Getting Started

### Prerequisites

- zsh
- git ≥ 2.5
- neovim (no plugins required) — validated with both a minimalist bare Vim setup and LazyVim
- claude (Claude Code CLI) — permission prompts stay on unless you opt in with `frame yolo on`
- docker with the compose v2 plugin (if running shared services)
- macOS + OrbStack (any docker provider works if already running; auto-start is OrbStack-only)
- curl, lsof

Frame also assumes **every project's default branch is named `main`**.

### Install Frame

```bash
# 1. Clone Frame
git clone https://github.com/scoop206/frame.git

# 2. Enter the repo
cd frame

# 3. Put frame on your PATH (this line persists it in ~/.zshrc)
echo "export PATH=\"$PWD/bin:\$PATH\"" >> ~/.zshrc
source ~/.zshrc

# 4. Verify
frame --help
```

### Onboarding a project

Scaffold a project's Frame config and boot your first frame in four steps.

**1. Go to your project.**

```bash
cd $YOUR_PROJECT
```

**2. Scaffold the Frame config.**

```bash
frame init
```

This writes three things:

- `.frame/config.sh` — the project config
- `.frame/local/` — gitignored, for personal overrides
- `.claude/settings.json` — claude-code hooks that put each frame's Claude into
  frame's lifecycle signaling:
  - `Stop` → `frame notify` (banner + "waiting" title) and `frame reply` (route a reply to a requester)
  - `UserPromptSubmit` → `frame status --prompt` ("working" title + turn-start stamp)
  - `Notification` → `frame notify --blocked` ("blocked" title + banner)
  - `SessionStart` → `frame swarm --context` (frame-awareness, when swarm ≥ 1)
  - `PostToolUse` → `frame reload-editor` (reloads the just-edited file into this frame's nvim buffer, when it's open)

**3. (Optional) Change which buffers your frames open.**
`frame init` already scaffolds a working default — `BUFFERS=(claude local)` — so you can skip straight
to booting a frame. Edit `.frame/config.sh` only if you want different buffers
(e.g. add `vite` or a backend `server`).

```bash
$EDITOR .frame/config.sh
```

**4. Boot a topic/worktree frame.** Neovim fires up with the Claude buffer in front.

```bash
frame wt scratch-topic
```

See [How a project plugs in](#how-a-project-plugs-in) for the full config.

## Worktrees

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

| command                   | action                                                                                                 |
| ------------------------- | ------------------------------------------------------------------------------------------------------ |
| `:FrameStatus TEXT…`      | append "- TEXT" to the window title's status suffix (no TEXT clears it)                                |
| `:FrameNotify off`        | 'on' or 'off' to unmute/mute banners; no arg shows state                                               |
| `:FrameQuit`              | quit the session only — worktree and branch stay for a later `frame wt TOPIC`                          |
| `:FrameDown`              | tear down the whole frame: quit nvim, remove the worktree, delete the branch                           |
| `:FrameDown!`             | force teardown — discard uncommitted changes and unmerged commits                                      |
| `:FrameMerge`             | merge this frame's branch into main (same safeguards as `frame merge`)                                 |
| `:FrameMerge!`            | merge, then push main to origin (mirrors `frame merge --push`)                                         |
| `:[range]FrameClaude [Q]` | open Claude buffer or use [range[ to ask this frame's claude about the current line / visual selection |

### Asking claude from the editor — `:FrameClaude`

`:FrameClaude` is the in-editor sibling of `frame claude`: it asks **this
frame's** claude about the code you're looking at, without leaving the buffer.

- **Bare `:FrameClaude`** sends the current line;
  **`:'<,'>FrameClaude`** (or any
  `:[range]`) sends the selected lines. The file and line range are attached as
  context, so claude knows what it's looking at.
- **`:FrameClaude <question>`** asks your own question about that code; with no
  question it defaults to "Review this code and give feedback."
- The reply renders in a reusable, read-only `[FrameClaude]` markdown scratch
  buffer that opens in a right-hand split (your cursor stays in the code). It
  shows a placeholder while claude works, then rewrites in place with the answer.

It shares the same broker and the same single claude conversation as
`frame claude` — so these turns enter that conversation like any other, and a
question asked while claude is busy simply queues. Unlike the socket clients, the
answer is pushed back in-process (no polling), so there's nothing to await. See
[docs/claude-broker.md](docs/claude-broker.md).

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

From inside the session, `:FrameMerge` runs the same thing for the current
frame's branch (`:FrameMerge!` also pushes); a blocked merge reports the
reason without leaving nvim.

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
`/tmp/frame/<name>-<topic>.teardown.log`.

### Closing a window vs. tearing down

Just closing a frame's window or tab (⌘W, the close button) is **suspend**,
not delete — and it's always safe:

- The frame's dir (or worktree + branch) survives. `frame shell TOPIC` /
  `frame wt TOPIC` later picks the frame back up where it left off —
  claude's session files and your work intact. Only `:FrameDown` /
  `frame wt -d` actually deletes.
- Processes die with the surface: if claude was mid-turn that work is lost,
  no reply routes home, and a head blocked on `frame inbox --wait` for it
  runs to its timeout.
- Bookkeeping self-heals. The nvim socket dies with nvim; a stale spawn
  recording (`.gtab`) is detected and dropped by `frame focus`; the next
  `frame spawn` validates its workers-window recording before reuse.
- One special case: an `--ephemeral` worker closed by hand never gets to
  self-reap, so its dir lingers in `~/frames` like any other closed frame.

Rule of thumb: close freely to get a worker out of the way; `:FrameDown`
when the topic should be gone.

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

### Inbox filtering

When you send a `frame req`, Frame prints a **token** (`token: frame/topic#id`) — a
globally-unique id for that request. Your inbox is shared: replies from every
`frame req` you've fired land there together, so reading in order can't guarantee
you're looking at the answer to a _specific_ request.

Pass `--for <token>` to `frame inbox` to retrieve only the reply for that request:

```bash
frame inbox --for frame/comms2#r7        # just that one answer
```

`--for` is repeatable, which makes it a fan-in barrier for correlated fan-out:
fire N reqs, capture each `token:` line, then wait for exactly those N answers —
unrelated mail landing mid-wait is left behind, not counted:

```bash
frame inbox --wait --for $t1 --for $t2   # blocks until both r1 and r2 arrive
```

See [docs/claude-broker.md](docs/claude-broker.md) for the full model.

## Swarm: telling agents they're in a frame

By default a frame's Claude doesn't know it's in a frame — it behaves as a lone
worker, blind to its own identity and its siblings. `frame swarm` changes that
by injecting a short block at every session start. It's a **dial, not a
switch**: each level injects strictly more, so token cost and permitted
behavior grow together.

```bash
frame swarm            # show the current level
frame swarm off        # (= 0) no injection — the default
frame swarm 1          # aware
frame swarm 2          # ask (the current ceiling)
frame swarm 3          # lead-frame fan-out/gather — not built yet, refused
```

| level           | what the agent is told                                                                                                                                                                                                                                                                                                                                                                                                                 |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **0 · off**     | nothing (the default)                                                                                                                                                                                                                                                                                                                                                                                                                  |
| **1 · aware**   | **who it is** — `NAME/TOPIC` + its dev-server URL, read from the frame's own environment (present only inside a real frame); and **the frame-safe way to act** — merge/tear down via `frame merge` / `frame wt -d` (not raw git), local merges are the agent's but pushing to origin stays with you, subagents it waits on run in the foreground, and a request from a sibling gets an answer, not an action. No sibling coordination. |
| **2 · ask**     | level 1 **plus** a bounded recipe for asking sibling frames read-only questions (`frame req` → `frame inbox --wait --for`, with a per-turn budget and a 2-hop limit). Find who to ask with `frame ls`.                                                                                                                                                                                                                                 |
| **3 · fan-out** | the ambitious top — lead-frame fan-out/gather. Not built yet, so **2 is the current ceiling**: selecting 3 is refused and points you back at 2.                                                                                                                                                                                                                                                                                        |

Like `frame yolo`, it's a machine-global dial that takes effect on the next
frame boot (or `/clear`, resume, compact) — running sessions keep what they
started with. `on`/`off` are accepted as aliases for `1`/`0`. When off, the
injection is a no-op that costs nothing, so solo repos that never coordinate
don't pay for it. It's wired through a `SessionStart` hook that `frame init`
scaffolds into `.claude/settings.json`.

**Extending the block per project.** Define `swarm_context()` in
`.frame/config.sh` (or `~/.config/frame/config.sh`, or `.frame/local/config.sh`)
and its output is appended after the built-in core — a natural home for a
one-line "this frame owns X" or a shared-infra heads-up. The core safety rules
are never overridable, so an append can only add, never drop a rule.

```sh
# .frame/config.sh
swarm_context() {
  echo "This frame owns pactduo-infra — the shared pg (5432) + minio (9000)."
}
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
