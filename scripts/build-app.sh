#!/bin/zsh
# Сборка Mistral.app: релиз-сборка всех таргетов, иконка, бандл, ad-hoc подпись.
set -e
set -o pipefail
cd "$(dirname "$0")/.."

echo "— swift build (release)…"
swift build -c release 2>&1 | grep -E "error:|Build complete"

echo "— иконка…"
if [ ! -f dist/AppIcon.icns ]; then
  mkdir -p dist
  swiftc scripts/makeicon.swift -o /tmp/mistral-makeicon
  /tmp/mistral-makeicon dist/icon-1024.png
  ICONSET=/tmp/Mistral.iconset
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 64 128 256 512; do
    sips -z $s $s dist/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    sips -z $d $d dist/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o dist/AppIcon.icns
fi

echo "— сборка бандла…"
APP=dist/Mistral.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Mistral  "$APP/Contents/MacOS/Mistral"
cp .build/release/Mistrald "$APP/Contents/MacOS/mistrald"
cp scripts/Info.plist      "$APP/Contents/Info.plist"
cp dist/AppIcon.icns       "$APP/Contents/Resources/AppIcon.icns"

echo "— ad-hoc подпись…"
codesign --force --sign - --timestamp=none "$APP"

echo "Готово: $APP"
