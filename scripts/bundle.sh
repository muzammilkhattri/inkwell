#!/bin/bash
# Builds Inkwell.app (release, Apple silicon) into ./build and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Inkwell.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Inkwell "$APP/Contents/MacOS/Inkwell"
if [ ! -f build/AppIcon.icns ] || [ Resources/AppIcon.png -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift Resources/AppIcon.png build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Inkwell</string>
  <key>CFBundleDisplayName</key><string>Inkwell</string>
  <key>CFBundleIdentifier</key><string>app.inkwell.mail</string>
  <key>CFBundleExecutable</key><string>Inkwell</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSContactsUsageDescription</key><string>Show photos of people you email.</string>
  <key>NSCalendarsWriteOnlyAccessUsageDescription</key><string>Add invitations to your calendar.</string>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>mailto</string><key>CFBundleURLSchemes</key><array><string>mailto</string></array></dict></array>
</dict></plist>
PLIST
# Signing identity, best first:
#  1. "Apple Development" (free Apple ID in Xcode → Settings → Accounts). Carries a Team ID, so the
#     Keychain's partition list stays the same across rebuilds and "Always Allow" sticks for good.
#  2. "Inkwell Local Signing" (scripts/make-signing-cert.sh). Self-signed certs have no Team ID, so the
#     Keychain keys access by cdhash and asks again after every rebuild.
#  3. Ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Apple Development:/ {print $2; exit}')
[ -z "$IDENTITY" ] && IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"Inkwell Local Signing"/ {print $2; exit}')
if [ -n "$IDENTITY" ]; then
  codesign --force --deep -s "$IDENTITY" "$APP"
else
  echo "warning: no signing certificate; using ad-hoc signing (run scripts/make-signing-cert.sh)"
  codesign --force --deep -s - "$APP"
fi
echo "Built $APP"
