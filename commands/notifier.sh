# The banner-app build — the app notify.sh prefers over osascript:
#
#   ~/.local/share/frame/Frame.app
#
# Run by `frame init` (best-effort, in a subshell): the first init on a
# machine builds it, so banners wear the frame icon out of the box. Also
# user-facing as `frame notification init` — the badge setup/repair command.
#
# A rebranded copy of terminal-notifier (brew). Being a real app bundle is
# the whole point: macOS banners wear the *sender's* icon, so the copy shows
# the frame vortex instead of Script Editor, and only the sending bundle
# gets the click callback — which is what lets notify.sh hang `frame focus`
# off the banner (-execute). Plain terminal-notifier -sender spoofs the icon
# but forfeits the callback; the rebranded copy keeps both.
#
# Later inits rebuild only when an input — the brew copy or
# assets/frame_badge.png — has changed; otherwise they skip. The skip is
# load-bearing: macOS keys the notification grant to the bundle's code
# signature, and the ad-hoc signing below mints a fresh signature every
# build — so a no-op rebuild would silently revoke the grant until
# re-allowed in System Settings. (To force a rebuild anyway, delete the
# bundle and run frame notification init.)
# Lives under $HOME (not FRAME_ROOT) because notification + Accessibility
# grants stick to the bundle path, which must not shift between frame
# worktrees.
# Run by init.sh as `frame notifier` — its own process, so a failed build
# can't take init down (init appends || true) and set -e stays live in here.
# Helpers + set -euo pipefail already active.

if ! command -v brew >/dev/null 2>&1; then
  echo "$X_MARK banner app skipped — needs homebrew (brew.sh); osascript banners still work" >&2
  exit 1
fi

# Never installs anything itself — a hint beats a package manager quietly
# hitting the network mid-init.
if ! SRC=$(brew --prefix terminal-notifier 2>/dev/null) || [[ ! -d "$SRC" ]]; then
  echo "$X_MARK banner app skipped — for frame-icon, click-to-focus banners:" >&2
  echo "    brew install terminal-notifier   # then: frame notification init" >&2
  exit 1
fi
# -d guard before the glob: with $SRC empty, "$SRC"/** would recursively
# crawl the whole filesystem from /.
[[ -d "$SRC" ]] || { echo "$X_MARK brew --prefix terminal-notifier gave no directory" >&2; exit 1 }
_apps=("$SRC"/**/terminal-notifier.app(N))
if (( ! $#_apps )); then
  echo "$X_MARK no terminal-notifier.app under $SRC — brew layout changed?" >&2
  exit 1
fi

APP="$HOME/.local/share/frame/Frame.app"
ICON_SRC="$FRAME_ROOT/assets/frame_badge.png"

# Fingerprint of the two build inputs — content only, no paths: paths would
# drag the brew version dir and this worktree's FRAME_ROOT in and force
# rebuilds that change nothing. A build stamps it into the bundle (below);
# a match here means rebuilding would reproduce what's already installed.
FINGERPRINT=$(cat "$_apps[1]/Contents/MacOS/terminal-notifier" "$ICON_SRC" \
  | shasum -a 256) && FINGERPRINT=${FINGERPRINT%% *}
FP_FILE="$APP/Contents/Resources/frame-fingerprint"
if [[ -f "$FP_FILE" && "$(<$FP_FILE)" == "$FINGERPRINT" ]]; then
  echo "$OK_MARK banner app already built — $APP"
  exit 0
fi

mkdir -p "${APP:h}"
rm -rf "$APP"
cp -R "$_apps[1]" "$APP"

# Icon: iconset rendered from the badge art, written over the bundle's own
# Terminal.icns so the plist's icon reference stays untouched. The PNG is
# pre-rendered from assets/frame_badge.svg (the editable source):
#   qlmanage -t -s 1024 -o assets assets/frame_badge.svg
#   mv assets/frame_badge.svg.png assets/frame_badge.png
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
# then re-sign — the icon/plist edits broke the original signature. The
# fingerprint stamp goes in first so the signature covers it.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.frame.notifier" \
                        -c "Set :CFBundleName Frame" "$APP/Contents/Info.plist"
print -r -- "$FINGERPRINT" > "$FP_FILE"
codesign --force --deep --sign - "$APP" 2>/dev/null

# Notification Center caches sender icons; restarting it (it respawns
# instantly) makes rebuilds with new art actually show up.
killall NotificationCenter 2>/dev/null || true

"$APP/Contents/MacOS/terminal-notifier" -title "frame" -sound Glass \
  -message "notifier installed — banners now look like this" >/dev/null 2>&1 || true

echo "$OK_MARK built $APP"
echo "  No banner? Allow it: System Settings → Notifications → Frame — the"
echo "  fresh signature dropped any earlier grant."
echo "  Click-to-focus asks for Accessibility on first click — grant that too."
