# Frame identity model & failure modes

*Design note. Captures why a frame's title is not its identity, and what does /
doesn't break when the title changes. Written while scoping the window-title
reformat (`name/topic` → `name [ topic ]`) and `frame ls`.*

## TL;DR

A frame has **two identity channels, and they don't share fate:**

| Channel | Source | User-mutable? | Depended on by |
|---|---|---|---|
| **Canonical identity** | nvim socket `/tmp/frame/<name>-<topic>.nvim` + `FRAME_NAME` / `FRAME_TOPIC` env | **No** — stamped at boot, immutable for the session's life | `frame ls`, `frame status`, `frame notify` |
| **Window title** | nvim `titlestring` (a *display* artifact) | Somewhat | `frame focus` **only** |

**Principle: the socket + env is the identity; the title is a derived,
disposable display artifact.** Anything that must reliably *find* a frame keys
off the socket. `frame focus` is the lone exception, and only because of a macOS
constraint (below).

Changing a title **cannot** hide a frame from `ls`, `status`, or `notify`. At
worst it can make `frame focus` unable to raise one specific window — and even
then the frame is not lost, just un-`focus`-able until its title is reset.

## Why `focus` is the exception

To raise a *specific* window, macOS `AXRaise` (via System Events) can only target
it **by its on-screen name** — see `commands/focus.sh`. There is no path from
"nvim socket" to "that Ghostty window," so `focus` must match on the window
title. This is an OS constraint, not a design choice.

`ls` / `status` / `notify` never touch the title: they open the socket and ask
the session directly over `--remote-expr` (see `commands/status.sh`), so they're
title-independent by construction.

## How exposed is the title dependency?

Ranked from safe to fragile:

1. **`frame status TEXT` — zero risk.** It only *appends* ` - TEXT`. The base
   `name [ topic :port ]` never changes (`layouts/worktree.lua` rebuilds the
   title from a fixed `base_title`), and `focus` matches on that base **prefix**,
   not the whole string. Freeform status never breaks focus.

2. **Stray shell / escape-sequence retitles — self-healing.** nvim sets
   `title=true` and *owns* the title for the whole session
   (`layouts/worktree.lua`: "nvim owns the title … shell integration can't
   overwrite it"). It re-asserts `titlestring` on redraw, so a `printf
   '\033]2;…'` or shell-integration title can't stick.

3. **The only real break: a deliberate override inside nvim** — `:set
   titlestring=…` or `:set notitle`. Now the window title diverges from the
   identity, and **only `frame focus` loses that window** (until the frame is
   rebooted or the title reset). `ls` / `status` / `notify` still find it via the
   socket. So even here the frame is not lost — only focus-by-title for it is.

## Design implications

- **Never make `ls` (or anything new) title-dependent.** Derive identity from the
  socket + env, exactly as `status.sh` does. The title is for humans, not for
  lookups.

- **Harden `focus` against the one fragile path.** On a title-match miss, check
  whether the frame's socket is alive; if it is, say so and point at the fix
  rather than blaming a closed frame / Accessibility:

  > `frame X is running but its window title was changed — reset it (reboot the
  > frame, or clear the title) and try again`

  Today `commands/focus.sh` prints "frame closed, or Accessibility not granted"
  for *every* miss, which actively misleads (it's what sent us hunting
  Accessibility permissions when the real cause was a `name/topic` vs `topic`
  mismatch). The socket check turns the one fragile path into a self-explaining,
  recoverable one.

## Related

- Window-title reformat spec (`name [ topic :port ] - WAITING`).
- `frame ls` spec — the first *new* consumer of the canonical-identity rule.
