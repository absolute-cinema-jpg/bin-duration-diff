#!/bin/bash
# Builds "Bin Duration Diff.app": a native Mac window (SwiftUI, mac/BinDurationDiff.swift)
# with the comparison engine (bin_diff.py + Python + bundled pyavb) inside it.
# Colleagues don't need Python, pip or the terminal.
# Universal build: runs on Intel and Apple Silicon Macs (macOS 11+).
# Needs only the Xcode Command Line Tools.
#
# Output: dist/Bin-Duration-Diff.zip  (app + "How to open.txt") -- share this,
#         or publish it as a GitHub release with ./release.sh
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

APP="Bin Duration Diff"
VERSION="${VERSION:-1.2.0}"   # override: VERSION=1.3.0 ./build_app.sh
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
SOURCES=(mac/App.swift mac/MainWindow.swift mac/Engine.swift mac/Settings.swift mac/Updater.swift mac/BugReport.swift)
mkdir -p build/swift
for arch in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library -target "$arch-apple-macos11.0" -sdk "$SDK" \
    "${SOURCES[@]}" -o "build/swift/app-$arch"
done
lipo -create build/swift/app-arm64 build/swift/app-x86_64 -output build/swift/app

# 3. Assemble the .app bundle
BUNDLE="dist/$APP.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp build/swift/app "$BUNDLE/Contents/MacOS/$APP"
cp -R build/engine/bin_diff_engine "$BUNDLE/Contents/Resources/engine"
cp vendor/avb/LICENSE-pyavb.txt "$BUNDLE/Contents/Resources/"
cp mac/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>by Alex Stuart</string>
  <key>CFBundleIdentifier</key><string>local.bin-duration-diff</string>
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
cat > "$SHARE/How to open.txt" <<'EOF'
BIN DURATION DIFF
Compares clip durations between two Avid bins. Clips are matched by tape name.

FIRST TIME ONLY
The app isn't from the App Store, so macOS blocks it the first time:
  1. Drag "Bin Duration Diff" into your Applications folder (optional).
  2. Double-click it. macOS will say it can't be opened. Click Done or OK.
  3. Open System Settings > Privacy & Security, scroll down, and click
     "Open Anyway" next to "Bin Duration Diff". Confirm with your password.
     (On macOS 13 or 14 you can instead right-click the app > Open > Open.)
After that it opens normally with a double-click.

USING IT
  1. Double-click the app. One window opens with Bin A and Bin B side by side.
  2. Click Choose... on each side, or drag the .avb bin files in from Finder
     (drag both at once to fill A and B together; the arrows button swaps them).
  3. Click Compare. The report opens in your web browser: every clip whose
     duration differs between the bins, biggest difference first.
  The window stays open, so you can compare another pair straight away.

SETTINGS (gear button, or Bin Duration Diff > Settings...)
  Where reports are saved, which sections and columns appear in the report,
  extra information (start timecode, frame counts, frame rate), and matching
  options such as ignoring differences of a frame or two.

UPDATES
  The app checks for a new version once a day and offers to install it.
  You can also use Bin Duration Diff > Check for Updates...
  For updates to install themselves, keep the app in your Applications folder.

PROBLEMS?
  Use the "Report a Bug..." button. It opens a ready-to-send GitHub issue
  (needs a free GitHub account).

Reports are saved in Documents > Bin Duration Reports (HTML + a CSV for Excel).
EOF
ZIP="dist/Bin-Duration-Diff.zip"
rm -f "$ZIP" "dist/$APP.zip"
ditto -c -k --sequesterRsrc "$SHARE" "$ZIP"

echo
echo "Built:  $BUNDLE  (version $VERSION)"
echo "Share:  $ZIP  ($(du -h "$ZIP" | cut -f1))"
