# frame

A personal dev-workflow harness: one place for the worktree/merge/dev-environment
choreography that would otherwise be copy-pasted (and drift) across project repos.

Run from inside any project checkout:

```
frame init                 scaffold .frame/config.sh, gitignore .frame/local/
frame wt TOPIC             create/reuse branch TOPIC + worktree ../_<name>-TOPIC, boot it
frame wt                   boot the worktree you're already in
frame wt -d TOPIC          quit its nvim, remove the worktree, delete the branch
frame merge [TOPIC] [--push|--ff|-n]   merge into main from the primary worktree
frame deploy-sans-tests    trigger the deploy workflow with skip_tests=true
frame services [up|down|ps]            manage the shared postgres/minio stack
```

All work happens in topic worktrees ("framelets"). Each is a self-sufficient
peer — `frame wt` runs the project's idempotent `stack_up()`, so whichever
framelet boots first brings up the shared services. The primary checkout is
just the git anchor that merges land on; it never needs a dev session.

Install: put `bin/` on your PATH.

## How a project plugs in

Everything project-side lives under one `.frame/` directory:

| path | committed? | contents |
|---|---|---|
| `.frame/config.sh` | yes | project facts: NAME, ports, SERVER_CMD, `stack_up()`, `app_env()` |
| `.frame/worktree.lua` | optional | project-level layout override |
| `.frame/local/` | never (gitignored) | personal overrides — `config.sh`/layouts here win |

Every setting is optional: a config of just `NAME=foo` (or none at all) still gets
`frame wt` and `frame merge`. Hooks:

- `stack_up()` — bring up whatever the dev stack needs. Runs on every `frame wt`
  boot, so keep it idempotent. Shared postgres/minio come from
  `frame_services_up` / `ensure_pg_db` / `ensure_minio_bucket`; only
  project-unique containers belong in the project's own compose file — pin
  those with `--project-directory "$MAIN_WT"` so every framelet shares one
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

Every framelet titles its ghostty window — `name/topic :port` — so Raycast's
window search can fuzzy-find
any of them. The title is set from the shell before nvim launches, then owned
by nvim (`title` + `titlestring`) for the session.
