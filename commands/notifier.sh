# frame notifier — build the banner app notify.sh prefers over osascript:
#
#   ~/.local/share/frame/Frame.app
#
# A rebranded copy of terminal-notifier (brew). Being a real app bundle is
# the whole point: macOS banners wear the *sender's* icon, so the copy shows
# the frame vortex instead of Script Editor, and only the sending bundle
# gets the click callback — which is what lets notify.sh hang `frame focus`
# off the banner (-execute). Plain terminal-notifier -sender spoofs the icon
# but forfeits the callback; the rebranded copy keeps both.
#
# Idempotent — re-run to rebuild from the current brew copy and
# assets/frame_badge.png. Lives under $HOME (not FRAME_ROOT) because
# notification + Accessibility grants stick to the bundle path, which must
# not shift between frame worktrees.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

if ! command -v brew >/dev/null 2>&1; then
  echo "$X_MARK frame notifier needs homebrew (brew.sh) to fetch terminal-notifier" >&2
  exit 1
fi

if ! SRC=$(brew --prefix terminal-notifier 2>/dev/null) || [[ ! -d "$SRC" ]]; then
  echo "$RUN_MARK installing terminal-notifier (brew)…"
  brew install terminal-notifier
  SRC=$(brew --prefix terminal-notifier)
fi
_apps=("$SRC"/**/terminal-notifier.app(N))
if (( ! $#_apps )); then
  echo "$X_MARK no terminal-notifier.app under $SRC — brew layout changed?" >&2
  exit 1
fi

APP="$HOME/.local/share/frame/Frame.app"
mkdir -p "${APP:h}"
rm -rf "$APP"
cp -R "$_apps[1]" "$APP"

# Icon: iconset rendered from the badge art, written over the bundle's own
# Terminal.icns so the plist's icon reference stays untouched. The PNG is
# pre-rendered from assets/frame_badge.svg (the editable source):
#   qlmanage -t -s 1024 -o assets assets/frame_badge.svg
#   mv assets/frame_badge.svg.png assets/frame_badge.png
ICON_SRC="$FRAME_ROOT/assets/frame_badge.png"
_tmp=$(mktemp -d)
mkdir "$_tmp/frame.iconset"
for _s in 16 32 64 128 256 512; do
  sips -z $_s $_s "$ICON_SRC" --out "$_tmp/frame.iconset/tmp_$_s.png" >/dev/null
done
cd "$_tmp/frame.iconset"
mv tmp_16.png icon_16x16.png
cp tmp_32.png icon_16x16@2x.png;   mv tmp_32.png icon_32x32.png
mv tmp_64.png icon_32x32@2x.png
mv tmp_128.png icon_128x128.png
cp tmp_256.png icon_128x128@2x.png; mv tmp_256.png icon_256x256.png
mv tmp_512.png icon_256x256@2x.png
cd - >/dev/null
iconutil -c icns "$_tmp/frame.iconset" -o "$APP/Contents/Resources/Terminal.icns"
rm -rf "$_tmp"

# Own identity (fresh notification-permission slot, callbacks routed here),
# then re-sign — the icon/plist edits broke the original signature.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.frame.notifier" \
                        -c "Set :CFBundleName Frame" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" 2>/dev/null

# Notification Center caches sender icons; restarting it (it respawns
# instantly) makes rebuilds with new art actually show up.
killall NotificationCenter 2>/dev/null || true

"$APP/Contents/MacOS/terminal-notifier" -title "frame" -sound Glass \
  -message "notifier installed — banners now look like this" >/dev/null 2>&1 || true

echo "$OK_MARK built $APP"
echo "  No banner? Allow it once: System Settings → Notifications → Frame."
echo "  Click-to-focus asks for Accessibility on first click — grant that too."
