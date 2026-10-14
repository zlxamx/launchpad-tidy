#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="dist/启动台整理.app"
mkdir -p dist
ARTIFACT_STAGE=$(mktemp -d "$PWD/dist/.stage.XXXXXX")
STAGED_APP="$ARTIFACT_STAGE/启动台整理.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp .build/release/LaunchpadTidy "$STAGED_APP/Contents/MacOS/LaunchpadTidy"
cp Resources/Info.plist "$STAGED_APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$STAGED_APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$STAGED_APP"
codesign --verify --strict "$STAGED_APP"
# Keep the old executable's inode intact if the previous version is still running.
PREVIOUS_APP=""
if [ -d "$APP" ]; then
  mkdir -p dist/previous-builds
  PREVIOUS_APP="dist/previous-builds/启动台整理-$(date +%Y%m%d-%H%M%S)-$RANDOM.app"
  mv "$APP" "$PREVIOUS_APP"
fi
if ! mv "$STAGED_APP" "$APP"; then
  if [ -n "$PREVIOUS_APP" ]; then mv "$PREVIOUS_APP" "$APP"; fi
  exit 1
fi
rmdir "$ARTIFACT_STAGE"
echo "已生成：$PWD/$APP"
