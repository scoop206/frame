# Examples

Three fictional projects showing what a committed `.frame/` directory looks
like, from nothing to a project with its own container. Copy the closest one
into your repo (or run `frame init` and edit) — the config is the whole
integration; there is nothing else to wire up.

| example                              | shows                                                                     |
| ------------------------------------ | ------------------------------------------------------------------------- |
| [`barebones/`](barebones)            | the minimum: `config.sh` with just `NAME`                                 |
| [`standard-web/`](standard-web)      | the default web stack: a server + vite app on the shared postgres/minio   |
| [`sidecar/`](sidecar)                | additionally running its own project-unique container from its compose file |

### barebones

Two lines that matter: the name, and the required `BUFFERS=(claude local)` —
this project has nothing to run in server/vite/ngrok, so it doesn't list
them. This is exactly how an infra/docs repo plugs in.

### standard-web

A typical app: `stack_up()` boots the shared postgres/minio and carves out
this project's tenant — a role + database via `ensure_pg_db`, a bucket via
`ensure_minio_bucket` (both idempotent, from `lib/helpers.sh`). `app_env()`
then exports `DATABASE_URL` etc. so the app talks to its tenant on the
standard ports. The server happens to be Rust here, but that's incidental —
`SERVER_CMD` is any command that starts a server (Go, Node, Python, …); only
the shape matters: claim a tenant in `stack_up()`, point the app at it in
`app_env()`. The `.gitignore` line for `.frame/local/` is what
`frame init` adds — personal overrides live there, never committed.

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

Buffer selection is separate from these values and fully explicit: the
required `BUFFERS=(…)` in `config.sh` lists exactly the buffers each frame
opens, chosen from the definitions in frame's
[`buffers.json`](../buffers.json) (see the main README's Buffers section).
Nothing is gated on the values above; a `server` buffer with no `SERVER_CMD`
opens as a bare shell, a `vite` buffer without `web/` fails visibly in its
buffer, and you either fill in the config or drop the buffer from `BUFFERS`.

### sidecar

Everything above, plus a project-unique container (an HTTP sidecar) defined
in the project's own `docker-compose.yml`. Two things keep it from
multiplying across frames:

- **profile-gated** (`profiles: ["sidecar"]`) so a bare `docker compose up`
  starts nothing extra;
- **`--project-directory "$MAIN_WT"`** pins compose to the primary checkout,
  so every frame shares one instance instead of each worktree deriving its
  own compose project and fighting over the port.

If you wanted a buffer tailing the sidecar's logs, its definition goes
_upstream_ — all buffer definitions live in frame's own `buffers.json`;
there is no project-level registry:

```json
{ "name": "sidecar-logs",
  "mode": "durable",
  "command": "docker compose --project-directory ${FRAME_MAIN_WT} logs -f sidecar" }
```

…and this project adds it to its list — `BUFFERS=(local server vite ngrok
sidecar-logs claude)`. No other project is affected: buffers open only where
`BUFFERS` names them.

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
