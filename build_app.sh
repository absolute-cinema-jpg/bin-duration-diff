#!/bin/bash
# Builds "Bin Diff.app": a native Mac window (SwiftUI, mac/*.swift) with the
# comparison engine (bin_diff.py + Python + bundled pyavb) inside it.
# Colleagues don't need Python, pip or the terminal.
# Universal build: runs on Intel and Apple Silicon Macs (macOS 11+).
# Needs only the Xcode Command Line Tools.
#
# Output: dist/Bin-Diff.zip  (app + "How to open.txt") -- share this,
#         or publish it as a GitHub release with ./release.sh
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

APP="Bin Diff"
VERSION="${VERSION:-2.1.0}"   # override: VERSION=1.3.0 ./build_app.sh
PY=/usr/bin/python3            # Apple's universal2 Python, needed for a universal engine
VENV=build/venv

# 1. Engine: bin_diff.py frozen with PyInstaller (command-line, no window of its own)
[ -x "$VENV/bin/python" ] || "$PY" -m venv "$VENV"
"$VENV/bin/python" -m pip install -q --disable-pip-version-check "pyinstaller==6.11.1"
"$VENV/bin/pyinstaller" --noconfirm --clean --log-level WARN \
  --onedir --console --name bin_diff_engine \
  --target-arch universal2 \
  --paths "$ROOT" --paths "$ROOT/vendor" --hidden-import avb \
  --distpath build/engine --workpath build/pyinstaller --specpath build \
  "$ROOT/bin_diff.py"

# 2. Window: compile the Swift front end for both architectures and merge
[ -f mac/AppIcon.icns ] || xcrun swift mac/make_icon.swift mac
SDK="$(xcrun --show-sdk-path)"
SOURCES=(mac/App.swift mac/MainWindow.swift mac/Engine.swift mac/Settings.swift mac/Updater.swift mac/BugReport.swift mac/ReportWindow.swift)
mkdir -p build/swift
for arch in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library -target "$arch-apple-macos11.0" -sdk "$SDK" \
    "${SOURCES[@]}" -o "build/swift/app-$arch"
done
lipo -create build/swift/app-arm64 build/swift/app-x86_64 -output build/swift/app

# 3. Assemble the .app bundle
# The bundle ID is from 1.x (when the app was "Bin Duration Diff"). Never change it:
# settings are stored under it, and the updater only installs an app with this ID.
BUNDLE_ID="local.bin-duration-diff"
BUNDLE="dist/$APP.app"
rm -rf "$BUNDLE" "dist/Bin Duration Diff.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp build/swift/app "$BUNDLE/Contents/MacOS/$APP"
cp -R build/engine/bin_diff_engine "$BUNDLE/Contents/Resources/engine"
cp vendor/avb/LICENSE-pyavb.txt LICENSE "$BUNDLE/Contents/Resources/"
cp mac/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>by Alex Stuart · GNU GPL v3</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
</dict></plist>
EOF
codesign --force --deep --sign - "$BUNDLE"    # ad hoc signature (not notarized)

# 4. Package for sharing
SHARE="build/share"
rm -rf "$SHARE" && mkdir -p "$SHARE"
cp -R "$BUNDLE" "$SHARE/"
cp mac/How-to-open.txt "$SHARE/How to open.txt"
ZIP="dist/Bin-Diff.zip"
rm -f dist/*.zip
ditto -c -k --sequesterRsrc "$SHARE" "$ZIP"

echo
echo "Built:  $BUNDLE  (version $VERSION)"
echo "Share:  $ZIP  ($(du -h "$ZIP" | cut -f1))"
