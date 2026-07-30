# Fixing a stuck banner badge

*Troubleshooting note. Captures a real debugging session where a rebuilt
`Frame.app` banner kept showing the **old** icon, and which escalation step
finally dislodged it. Written after swapping the badge art from the original
design to the v2 terracotta-N badge.*

## Context

The badge art was being upgraded — an older `Frame.app` badge was already
installed and granted notification permission, and we swapped in new art
(`assets/frame_badge.svg` → `assets/frame_badge.png` → the `.icns` inside
`~/.local/share/frame/Frame.app`). `frame notification init` rebuilt the bundle
cleanly, but macOS banners kept wearing the **old** icon. Rebuilding again,
and the README's `killall usernoted NotificationCenter` hint, did nothing.

## TL;DR

The on-disk art was correct the whole time — SVG, committed PNG, and the
bundle's `.icns` all carried the new badge. The staleness lived in **macOS's
icon cache**, keyed to the bundle identifier `dev.frame.notifier`. Because that
identifier is **stable across rebuilds**, macOS keeps serving the first icon it
ever associated with the bundle. `killall usernoted NotificationCenter` only
restarts the *notification UI* — it never touches the icon layer, so it can't
fix this.

**What finally worked: bouncing the Dock and `iconservicesagent` together**
(after clearing the on-disk icon store). See Tier 2 below.

## Why the obvious fix doesn't work

macOS serves a notification app's icon through `iconservicesagent` /
LaunchServices / the Dock, not through the notification daemons. So:

- `killall usernoted NotificationCenter` → restarts the banner UI only. The
  icon is cached elsewhere and survives this. **Insufficient.**
- Rebuilding the bundle → correctly writes the new `.icns`, but the icon cache
  is keyed to the *stable* bundle ID `dev.frame.notifier`, so macOS keeps
  serving the previously-cached icon for that ID regardless of what's on disk.

## What we ran (escalation ladder)

Run from Tier 1; stop as soon as the new badge appears. In this session Tier 1
did **not** work; **Tier 2 did.**

### Tier 1 — re-register the bundle + flush the icon agent (no sudo)

```bash
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f ~/.local/share/frame/Frame.app
killall iconservicesagent 2>/dev/null
killall usernoted NotificationCenter 2>/dev/null
frame notify
```

Result in this session: **no change.** `lsregister -f` refreshes LaunchServices'
record of the freshly-signed bundle, and `killall iconservicesagent` restarts
the icon agent — but the Dock-side cache still held the old art.

> Note: `killall` reporting `No matching processes` is harmless — the agent
> isn't always running and respawns on demand. And the process is
> `iconservice**s**agent` (services, plural); `iconserviceagent` is a typo that
> silently matches nothing.

### Tier 2 — clear the on-disk icon store + bounce Dock (needs sudo) — **this fixed it**

```bash
sudo rm -rf /Library/Caches/com.apple.iconservices.store
sudo find /private/var/folders -name com.apple.iconservices -type d -exec rm -rf {} + 2>/dev/null
killall Dock iconservicesagent usernoted NotificationCenter 2>/dev/null
frame notify
```

The operative step was **`killall Dock iconservicesagent`** — restarting the
Dock alongside the icon agent is what dislodged the cached icon. (The
`/private/var/folders` `find` produced no output here, so the per-user store
wasn't the culprit; the `/Library/Caches` store removal plus the Dock bounce
did it.) The Dock visibly blinks when restarted — that's expected, and the
icon caches rebuild themselves automatically.

### Tier 3 — if it still won't budge

Log out and back in (or reboot), then `frame notify`. This makes macOS re-see
the app fresh and is the reliable last resort. A logout is almost always enough
short of a full restart.

## Why this isn't baked into `frame notification init`

This only bites when the badge art **changes** on a bundle macOS has already
cached — i.e. someone iterating on the icon. A first-time install has no old
icon to get stuck behind, so the normal build path works and the existing
README hint is fine.

Paying a Dock-bounce (and `sudo`) tax on every rebuild to cover a scenario
almost nobody else hits would be the wrong trade, and it fights the deliberate
"killing services is the user's call, so it's a printed hint, not code" design
in `commands/notifier.sh`. So the fix stays a manual procedure — documented
here — rather than automation. If icon churn ever makes this recurring, the
cheap next step is a one-line addition to that command's printed hint pointing
at the `killall Dock iconservicesagent` icon-cache tier.
