# Examples

Three fictional projects showing what a committed `.frame/` directory looks
like, from nothing to a project with its own container. Copy the closest one
into your repo (or run `frame scaffold` and edit) — the config is the whole
integration; there is nothing else to wire up.

| example                              | shows                                                                     |
| ------------------------------------ | ------------------------------------------------------------------------- |
| [`barebones/`](barebones)            | the minimum: `config.sh` with just `NAME`                                 |
| [`shared-services/`](shared-services)| a project using the shared postgres/minio (`stack_up()` + `app_env()`)    |
| [`sidecar/`](sidecar)                | additionally running its own project-unique container, plus a custom buffer for its logs |

### barebones

One file, one line that matters. `frame wt` and `frame merge` work with just
a name; with no `SERVER_CMD`, no `web/`, and no ports, the when-gates in
frame's `buffers.json` skip the server/vite/ngrok buffers automatically —
every frame gets just `local` and `claude`. This is exactly how an infra/docs
repo plugs in.

### shared-services

A typical app: `stack_up()` boots the shared postgres/minio and carves out
this project's tenant — a role + database via `ensure_pg_db`, a bucket via
`ensure_minio_bucket` (both idempotent, from `lib/helpers.sh`). `app_env()`
then exports `DATABASE_URL` etc. so the app talks to its tenant on the
standard ports. The `.gitignore` line for `.frame/local/` is what
`frame scaffold` adds — personal overrides live there, never committed.

#### Choosing `SERVER_CMD` and the ports

These aren't frame-assigned values — they come from your project:

- **`SERVER_CMD`** is whatever command already starts your dev server
  (`cargo run -p …`, `npm run server`, `python manage.py runserver`, …). It
  runs verbatim in the layout's `server` terminal buffer; omit it and the
  buffer is skipped. The one requirement: the server must bind the exported
  `$PORT` rather than a hardcoded port.
- **`API_PORT` / `VITE_PORT` / `HMR_PORT`** are the ports your primary
  checkout normally uses — your server's dev default, and vite's defaults
  (`5173` dev server, `24678` HMR websocket) unless you've changed them.
  They are *bases*, not fixed assignments: on boot each frame scans upward
  from them for free ports (primary gets 3000/5173/24678, the first worktree
  3001/5174/24679, …) and exports the winners as `PORT` plus
  `<NAME>_API_PORT` / `<NAME>_VITE_PORT` / `<NAME>_HMR_PORT` (name
  upper-cased, dashes → underscores). Your server and `web/vite.config.*`
  must read those env vars for parallel frames to coexist.
- Running several projects' primary envs side by side? Give each project its
  own bases (e.g. 3000/5173/24678 and 3100/5273/24778) — upward scanning
  would resolve collisions anyway, but distinct bases keep each project's
  ports predictable.
- A project with no web app or server just omits all of these (see
  `barebones`) — no ports are scanned or exported.

The same values drive which buffers each frame opens: `SERVER_CMD` gates the
`server` buffer, a `web/` directory gates `vite`, and the port config gates
`ngrok` — the `when` clauses in frame's [`buffers.json`](../buffers.json)
registry (see the main README's Buffers section). To pin an exact list
instead, set `BUFFERS=(…)` in `config.sh` — the commented line in this
example shows how.

### sidecar

Everything above, plus a project-unique container (a "worker" HTTP sidecar)
defined in the project's own `docker-compose.yml`. Two things keep it from
multiplying across frames:

- **profile-gated** (`profiles: ["worker"]`) so a bare `docker compose up`
  starts nothing extra;
- **`--project-directory "$MAIN_WT"`** pins compose to the primary checkout,
  so every frame shares one instance instead of each worktree deriving its
  own compose project and fighting over the port.

It also ships a `.frame/buffers.json`: a project-unique `worker-logs` buffer
tailing the sidecar's logs. Project entries merge over frame's registry by
name, so this buffer appears in every frame (slotted before `claude`) without
forking the whole `worktree.lua` layout — and `${FRAME_MAIN_WT}` in its
command is interpolated at boot, pointing compose at the shared instance.

## Setting up the shared containers

There is no per-project setup — the centralized postgres/minio belong to
frame itself ([`services/docker-compose.yml`](../services/docker-compose.yml)),
not to any project, which is why they don't appear inside the examples'
directories.

- **First boot:** nothing to do in advance. `frame wt` runs the project's
  `stack_up()`, and its `frame_services_up` call starts the containers
  (auto-starting OrbStack if docker isn't up) and waits for them to be
  healthy. Whichever frame boots first brings the stack up for everyone.
- **Manually:** `frame services up` / `frame services down` / `frame services ps`
  from anywhere.
- **Multi-tenancy:** one postgres on `:5432` and one minio on `:9000`/`:9001`
  serve every project. Each project claims its slice in `stack_up()` —
  `ensure_pg_db NAME` creates a role + database owned by that role (so one
  project's tests can't touch another's data), `ensure_minio_bucket BUCKET`
  creates its bucket. Standard ports, no per-project offsets.
- **Data** lives in named docker volumes (`pgdata`, `miniodata`) and survives
  `frame services down`.
