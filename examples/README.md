# Examples

Three fictional projects showing what a committed frame integration looks like,
from nothing to a project with its own container. Each carries the two pieces
`frame init` scaffolds — a `.frame/config.sh` and a `.claude/settings.json` — so
copying the closest one into your repo (or running `frame init` and editing)
leaves nothing else to add.

| example                         | shows                                                                       |
| ------------------------------- | --------------------------------------------------------------------------- |
| [`barebones/`](barebones)       | the minimum: `config.sh` with just `NAME`                                    |
| [`standard-web/`](standard-web) | the default web stack: a server + vite app on the shared postgres/minio     |
| [`sidecar/`](sidecar)           | additionally running its own project-unique container from its compose file |

The `.claude/settings.json` is identical in all three — frame writes the same
canonical hooks for every project (see the main README's
[Onboarding a project](../README.md#onboarding-a-project) step for the
event-by-event breakdown). The `.frame/config.sh` is the part that varies, and
it's what each example is really about.

For the general mechanics these examples draw on, see the main README:
[config.sh keys and the `stack_up()` / `app_env()` hooks](../README.md#configsh),
[port assignment](../README.md#port-assignment),
[buffers](../README.md#buffer-definitions), and
[shared services](../README.md#shared-centralized-services). What's distinctive
about each example is below.

### barebones

Two lines that matter: the name, and the required `BUFFERS=(claude local)` —
this project has nothing to run in server/vite/ngrok, so it doesn't list them.
This is exactly how an infra/docs repo plugs in.

### standard-web

`stack_up()` carves out this project's tenant on the shared postgres/minio — a
role + database via `ensure_pg_db`, a bucket via `ensure_minio_bucket` — and
`app_env()` exports `DATABASE_URL` etc. so the app talks to it. The server
happens to be Rust here, but that's incidental: `SERVER_CMD` is any command that
starts a server (Go, Node, Python, …). Only the shape matters — claim a tenant
in `stack_up()`, point the app at it in `app_env()`.

### sidecar

Everything above, plus a project-unique container (an HTTP sidecar) defined in
the project's own `docker-compose.yml`. Two things keep it from multiplying
across frames: it's **profile-gated** (`profiles: ["sidecar"]`) so a bare
`docker compose up` starts nothing extra, and it's pinned with
`--project-directory "$MAIN_WT"` so every frame shares one instance instead of
each worktree spawning its own. A buffer tailing its logs would just be added to
`BUFFERS`, with the buffer itself defined upstream in
[`buffers.json`](../buffers.json).
