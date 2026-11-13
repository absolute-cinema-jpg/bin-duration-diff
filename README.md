# Bin Duration Diff

Compare clip durations between two Avid bins. Clips are matched by **tape name**; every clip whose duration differs is flagged, and the differences are ranked biggest first in an HTML report (plus a CSV).

<img src="mac/AppIcon.png" width="96" alt="App icon">

## For editors: the Mac app

1. Download **Bin-Duration-Diff.zip** from the [latest release](https://github.com/absolute-cinema-jpg/bin-duration-diff/releases/latest) and unzip it.
2. Drag **Bin Duration Diff** into your Applications folder.
3. First launch only: double-click it, click **Done** on the warning, then go to **System Settings → Privacy & Security** and click **Open Anyway**. (On macOS 13/14 you can right-click the app → **Open** instead.)
4. Choose or drag in **Bin A** and **Bin B**, then click **Compare**. The report opens in your browser and is saved to `Documents/Bin Duration Reports` (you can change this in Settings).

The app checks for updates once a day and can install them itself. **Report a Bug…** opens a pre-filled GitHub issue.

Runs on Intel and Apple Silicon Macs, macOS 11 or later. Python and everything else it needs are inside the app.

### Settings

- Where reports are saved; whether to open them automatically; CSV on/off
- Ignore differences of up to N frames; case-sensitive tape names; include subclips
- Report sections (summary, only in A/B, no tape name, same duration, full paths)
- Differences-table columns, plus optional extras: start timecode, frame counts, frame rate

## Inputs

- `.avb` Avid bins, read directly (via a bundled copy of [pyavb](https://github.com/markreidvfx/pyavb), MIT licence)
- `.ale` exports
- Tab-delimited bin exports (`.txt`/`.tab`/`.tsv`/`.csv`) with Tape and Duration (or Start + End) columns

Master clips are compared; a bin with only subclips (e.g. AutoSync bins) uses its subclips. Hidden reference clips inside a bin are ignored.

## Command line

```bash
python3 bin_diff.py "Picture.avb" "Sync.avb" --open
python3 bin_diff.py A.avb B.avb --tolerance 2 --show start_tc,frames --hide same,magnitude
python3 bin_diff.py --help
```

No installs needed — pyavb is in `vendor/`.

## Building and releasing

Needs the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build_app.sh                      # -> dist/Bin Duration Diff.app and dist/Bin-Duration-Diff.zip
./release.sh 1.2.1 "What changed"   # builds that version and publishes a GitHub release
```

The in-app updater installs the newest GitHub release whose tag (`vX.Y.Z`) is higher than the running version, so bump the version for every release.

| Path | What it is |
| --- | --- |
| `bin_diff.py` | The comparison engine and report writer |
| `mac/` | SwiftUI app (window, settings, updater, bug report) and the icon |
| `vendor/avb` | pyavb 1.4.0 |
| `build_app.sh` / `release.sh` | Build the app / publish a release |

---
by Alex Stuart
