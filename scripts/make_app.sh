#!/bin/bash
# Build BBoxDesigner.app from the SPM release binary.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=BBoxDesigner.app
BIN=.build/release/BBoxDesigner
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BBoxDesigner"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BBoxDesigner</string>
  <key>CFBundleExecutable</key><string>BBoxDesigner</string>
  <key>CFBundleIdentifier</key><string>local.bboxdesigner.app</string>
  <key>CFBundleVersion</key><string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP" 2>/dev/null || true

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" || true

# 同步最新版本到桌面(若桌面上已有旧版则替换)
DESKTOP_APP="$HOME/Desktop/BBoxDesigner.app"
if [ "$(pwd)" != "$HOME/Desktop" ]; then
  rm -rf "$DESKTOP_APP"
  cp -R "$APP" "$HOME/Desktop/"
  xattr -cr "$DESKTOP_APP" 2>/dev/null || true
  [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DESKTOP_APP" || true
  echo "synced to $DESKTOP_APP"
fi

echo "built $APP — open with: open $APP"
