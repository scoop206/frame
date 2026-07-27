# frame

An opinionated AI harness based around:

- neovim
- git worktrees

Run from inside any project checkout:

```
frame init                 scaffold .frame/config.sh, gitignore .frame/local/
frame wt TOPIC             create/reuse branch TOPIC + worktree ../_<name>-TOPIC, boot it
frame wt                   boot the worktree you're already in
frame wt -d [-f] [TOPIC]   tear down a frame (defaults to the one you're in)
frame merge [TOPIC] [--push|--ff|-n]   merge into main from the primary worktree
frame deploy-sans-tests    trigger the deploy workflow with skip_tests=true
frame services [up|down|ps]            manage the shared postgres/minio stack
frame status [TEXT…]       append "- TEXT" to this frame's window title (no TEXT clears)
```

### Frames

All work happens in topic worktrees, each called a "frame" — the same name as
the framework itself. Each is a self-sufficient peer — `frame wt` runs the
project's idempotent `stack_up()`, so whichever frame boots first brings up
the shared services.

`frame wt TOPIC` is the typical entrypoint.

For example:
This starts neovim w/ custom layout which is usually 4 buffers:

- claude - starts claude-code
- vite - cd web && npm run dev
- server - cargo run -p $PROJECT-server
- local - bare terminal

The ghostty window will now be named $REPO/$TOPIC:PORT
You can see vite's rendered web app at http://localhost:PORT

When you are done working on the feature you (or claude) can merge to main:

```
frame merge
```

### Status

The window title's base — `$REPO/$TOPIC :PORT` — never changes, but you can
append a free-text status to it so parallel frames show where they're at:

- in any terminal buffer (including claude): `frame status DEPLOYED. Waiting verification`
- in nvim: `:FrameStatus DEPLOYED. Waiting verification`

Either with no text clears back to the base title.

The CLI form works by RPC over the frame's nvim socket (nvim owns the title),
so it also works from outside the frame while its session is up.

### Frame Removal

To merely close the session — keeping the worktree and branch for a later
`frame wt TOPIC` — use `:FrameQuit` (≡ `:qa!`).

Tear down from _inside_ the frame — either entry point works:

- in nvim: `:FrameDown` (from a terminal buffer, `<C-\><C-n>` first)
- in any terminal buffer: `frame wt -d`

Both hand the teardown to a detached reaper rooted in the primary checkout.
It sends `:qa!` to the nvim session (works from terminal-insert mode, and the
`!` bypasses vimrc quit guards), waits for nvim to actually exit, then removes
the worktree and deletes the branch. The ghostty window closes with nvim —
one command and the whole frame is gone.

From outside (base terminal or another frame): `frame wt -d TOPIC`.

Teardown refuses if the worktree has uncommitted changes or the branch has
commits not yet on main — merge first (`frame merge`), or force with
`frame wt -d -f [TOPIC]` / `:FrameDown!`. These checks run _before_ nvim is
quit, so a refusal never leaves you editor-less. Reaper output lands in
`/tmp/<name>-<topic>.teardown.log`.

### Install

Clone this repo alongside your projects.  
put `/path/to/frame/bin/` on your PATH.  
add a .frame directory to the projects w/ optional components see below.

### Dependencies

Hard requirements:

- zsh
- git ≥ 2.5
- neovim (no plugins required)
- claude (Claude Code CLI)
- docker with the compose v2 plugin
- macOS + OrbStack (any docker provider works if already running; auto-start is OrbStack-only)
- curl, lsof

Needed only by specific commands or buffers:

- gh, authenticated (`frame deploy-sans-tests`)
- node + npm (the `vite` buffer, when the project has `web/`)
- ngrok (optional; prefilled, never auto-run)
- ghostty + Raycast (optional; window titling/search)

## How a project plugs in

Everything project-side lives under one `.frame/` directory:

| path                  | committed?         | contents                                                          |
| --------------------- | ------------------ | ----------------------------------------------------------------- |
| `.frame/config.sh`    | yes                | project facts: NAME, ports, SERVER_CMD, `stack_up()`, `app_env()` |
| `.frame/worktree.lua` | optional           | project-level layout override                                     |
| `.frame/local/`       | never (gitignored) | personal overrides — `config.sh`/layouts here win                 |

Every setting is optional: a config of just `NAME=foo` (or none at all) still gets
`frame wt` and `frame merge`. Hooks:

- `stack_up()` — bring up whatever the dev stack needs. Runs on every `frame wt`
  boot, so keep it idempotent. Shared postgres/minio come from
  `frame_services_up` / `ensure_pg_db` / `ensure_minio_bucket`; only
  project-unique containers belong in the project's own compose file — pin
  those with `--project-directory "$MAIN_WT"` so every frame shares one
  instance instead of spawning a per-worktree compose project.
- `app_env()` — export the vars pointing the app at the shared services
  (`DATABASE_URL`, S3 endpoint, …); exported vars win over `.env` (dotenvy
  never overrides the environment).

## Shared services

`services/docker-compose.yml` runs one postgres (`:5432`) and one minio
(`:9000`/`:9001`) for all projects — multi-tenant via databases/roles and
buckets, standard ports, no per-project offsets. Helper functions in
`lib/helpers.sh` create roles/databases/buckets idempotently.

## Windows

Every frame titles its ghostty window — `name/topic :port` — so Raycast's
window search can fuzzy-find
any of them. The title is set from the shell before nvim launches, then owned
by nvim (`title` + `titlestring`) for the session.
