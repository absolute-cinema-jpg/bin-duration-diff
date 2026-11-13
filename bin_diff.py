#!/usr/bin/env python3
"""
bin_diff.py - compare two Avid bins and report every difference.

Clips are linked by TAPE NAME. For each pair of linked clips, every other
metadata column the two bins share is compared (Name, Duration, Start, End,
Tracks, FPS, user columns such as Scene / Take / Comments, ...). Duration
differences are also ranked biggest-first. Output: an HTML report plus a CSV.

Accepted inputs (each side can be any of these):
  * .avb   Avid bin, read directly (pyavb is bundled in ./vendor)
  * .ale   Avid Log Exchange export
  * .txt / .tab / .tsv / .csv   Bin export (File > Export > Tab Delimited).
           Needs a Tape column. Every other column is compared.

Usage:
  python3 bin_diff.py BIN_A BIN_B [-o report.html] [--fps 23.976]
                      [--tolerance 0] [--ignore-columns "Modified Date,Comments"]
                      [--include-subclips] [--open]

Copyright (C) 2026 Alex Stuart. Licensed under the GNU GPL v3 (see LICENSE).
"""

from __future__ import annotations

import argparse
import csv
import datetime as _dt
import html
import json
import os
import re
import sys
import webbrowser
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Tuple

# Use the bundled copy of pyavb (vendor/avb) so nothing needs to be pip-installed.
_HERE = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
_VENDOR = os.path.join(_HERE, "vendor")
if os.path.isdir(_VENDOR) and _VENDOR not in sys.path:
    sys.path.insert(0, _VENDOR)

APP_NAME = "Bin Diff"


# --------------------------------------------------------------------------- #
# Timecode helpers
# --------------------------------------------------------------------------- #

def nominal_fps(fps: float) -> int:
    return int(round(fps))


def tc_to_frames(tc: str, fps: float) -> Optional[int]:
    """Parse timecode ('01:00:10:12', drop-frame ';'), feet+frames ('12+05')
    or a plain frame count. Returns None if it can't be parsed."""
    if tc is None:
        return None
    tc = tc.strip()
    if not tc:
        return None
    if re.fullmatch(r"-?\d+", tc):
        return int(tc)
    m = re.fullmatch(r"(\d+)\+(\d+)", tc)  # 35mm 4-perf feet+frames
    if m:
        return int(m.group(1)) * 16 + int(m.group(2))
    m = re.fullmatch(r"(\d+)[:;.](\d+)[:;.](\d+)([:;.,])(\d+)", tc)
    if not m:
        return None
    h, mi, s, sep, f = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4), int(m.group(5))
    base = nominal_fps(fps)
    frames = (h * 3600 + mi * 60 + s) * base + f
    if (sep in ";," or ";" in tc) and base in (30, 60):
        drop = 2 if base == 30 else 4
        total_min = h * 60 + mi
        frames -= drop * (total_min - total_min // 10)
    return frames


def frames_to_tc(frames: int, fps: float) -> str:
    """Duration-style timecode (non-drop at nominal rate), with sign."""
    sign = "-" if frames < 0 else ""
    frames = abs(int(frames))
    base = nominal_fps(fps) or 24
    f = frames % base
    s = frames // base
    return "%s%02d:%02d:%02d:%02d" % (sign, s // 3600, (s // 60) % 60, s % 60, f)


def frames_to_clock_tc(frames: int, base: int, drop: bool = False) -> str:
    """Frame count -> wall-clock timecode (e.g. a start TC), drop-frame aware."""
    frames = max(0, int(frames))
    if drop and base in (30, 60):
        d = 2 if base == 30 else 4
        per_min = base * 60 - d
        per_10 = per_min * 10 + d
        tens, rem = divmod(frames, per_10)
        frames += d * 9 * tens + (d * ((rem - d) // per_min) if rem > d else 0)
    f = frames % base
    s = frames // base
    sep = ";" if drop and base in (30, 60) else ":"
    return "%02d:%02d:%02d%s%02d" % ((s // 3600) % 24, (s // 60) % 60, s % 60, sep, f)


def fmt_fps(fps: float) -> str:
    return ("%.3f" % fps).rstrip("0").rstrip(".")


def signed_tc(d: int, fps: float) -> str:
    return ("+" if d > 0 else "") + frames_to_tc(d, fps)


# --------------------------------------------------------------------------- #
# Clip model
# --------------------------------------------------------------------------- #

@dataclass
class Clip:
    name: str
    tape: str
    frames: Optional[int]          # duration in frames (None = unknown)
    fps: float
    kind: str = "clip"             # master / subclip / clip
    raw_duration: str = ""
    start_tc: str = ""             # source start timecode, when known
    meta: "OrderedDict[str, str]" = field(default_factory=OrderedDict)  # column -> value (not Tape)

    def value(self, column: str) -> str:
        """Value of a column, matched without regard to case."""
        v = self.meta.get(column)
        if v is None:
            low = column.lower()
            v = next((val for k, val in self.meta.items() if k.lower() == low), "")
        return v or ""


@dataclass
class Bin:
    path: str
    clips: List[Clip] = field(default_factory=list)
    columns: List[str] = field(default_factory=list)   # metadata columns found (not Tape)
    unreadable: List[str] = field(default_factory=list)  # .avb: shown in the bin view, no values found

    @property
    def label(self) -> str:
        return os.path.basename(self.path)

    def add_columns(self, names):
        have = {c.lower() for c in self.columns}
        for n in names:
            if n and n.lower() not in have:
                self.columns.append(n)
                have.add(n.lower())


def dur_tc(c: Clip) -> str:
    return frames_to_tc(c.frames, c.fps) if c.frames is not None else (c.raw_duration or "")


# --------------------------------------------------------------------------- #
# Readers
# --------------------------------------------------------------------------- #

TAPE_COLS = ["tape", "tape name", "tapename", "source tape", "tape id"]
NAME_COLS = ["name", "clip name", "clipname"]
DUR_COLS = ["duration", "dur", "length"]
START_COLS = ["start", "start tc", "start timecode"]
END_COLS = ["end", "end tc", "end timecode"]
FPS_COLS = ["fps", "frame rate", "project rate"]


def _find_col(header: List[str], candidates: List[str], override: Optional[str] = None) -> Optional[int]:
    norm = [h.strip().lower() for h in header]
    if override:
        o = override.strip().lower()
        return norm.index(o) if o in norm else None
    for c in candidates:
        if c in norm:
            return norm.index(c)
    return None


def _read_text(path: str) -> str:
    raw = open(path, "rb").read()
    for enc in ("utf-8-sig", "utf-16", "mac_roman"):
        try:
            text = raw.decode(enc)
            if enc == "utf-16" and not raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
                continue
            return text
        except UnicodeDecodeError:
            continue
    return raw.decode("latin-1")


def parse_fps(value: str) -> Optional[float]:
    try:
        v = float(str(value).strip().split()[0])
        return v if v > 0 else None
    except (ValueError, IndexError):
        return None


def rows_to_bin(path: str, header: List[str], rows: List[List[str]], fps: float, args) -> Bin:
    b = Bin(path)
    header = [h.strip() for h in header]
    i_tape = _find_col(header, TAPE_COLS, args.tape_column)
    i_name = _find_col(header, NAME_COLS)
    i_dur = _find_col(header, DUR_COLS, args.duration_column)
    i_start = _find_col(header, START_COLS)
    i_end = _find_col(header, END_COLS)
    i_fps = _find_col(header, FPS_COLS)

    if i_tape is None:
        raise SystemExit("%s: no Tape column found. Columns are: %s\n"
                         "Add the Tape column to the bin view before exporting, "
                         "or pass --tape-column." % (os.path.basename(path), ", ".join(header)))

    # Every column except Tape is metadata to compare (first occurrence of each name).
    meta_cols = []
    seen = set()
    for i, h in enumerate(header):
        if i == i_tape or not h or h.lower() in seen:
            continue
        seen.add(h.lower())
        meta_cols.append((i, h))
    b.add_columns([h for _, h in meta_cols])

    def cell(row, i):
        return row[i].strip() if i is not None and i < len(row) else ""

    for row in rows:
        if not any(c.strip() for c in row):
            continue
        row_fps = parse_fps(cell(row, i_fps)) or fps
        raw = cell(row, i_dur)
        frames = tc_to_frames(raw, row_fps) if raw else None
        if frames is None and i_start is not None and i_end is not None:
            s, e = tc_to_frames(cell(row, i_start), row_fps), tc_to_frames(cell(row, i_end), row_fps)
            if s is not None and e is not None:
                frames = e - s
                raw = raw or "%s - %s" % (cell(row, i_start), cell(row, i_end))
        meta = OrderedDict((h, cell(row, i)) for i, h in meta_cols)
        b.clips.append(Clip(name=cell(row, i_name) or "(unnamed)", tape=cell(row, i_tape),
                            frames=frames, fps=row_fps, raw_duration=raw,
                            start_tc=cell(row, i_start), meta=meta))
    return b


def read_delimited(path: str, args) -> Bin:
    text = _read_text(path)
    lines = text.splitlines()
    sample = "\n".join(lines[:5])
    delim = "\t" if "\t" in sample else ","
    rows = list(csv.reader(lines, delimiter=delim))
    rows = [r for r in rows if any(c.strip() for c in r)]
    if not rows:
        raise SystemExit("%s: file is empty" % os.path.basename(path))
    return rows_to_bin(path, rows[0], rows[1:], args.fps, args)


def read_ale(path: str, args) -> Bin:
    lines = _read_text(path).splitlines()
    section, header, rows, fps = None, None, [], None
    for line in lines:
        key = line.strip().lower()
        if key in ("heading", "column", "data"):
            section = key
            continue
        if not line.strip():
            continue
        if section == "heading":
            parts = line.split("\t")
            if parts[0].strip().lower() == "fps" and len(parts) > 1:
                fps = parse_fps(parts[1])
        elif section == "column" and header is None:
            header = line.split("\t")
        elif section == "data":
            rows.append(line.split("\t"))
    if header is None:
        raise SystemExit("%s: doesn't look like an ALE (no Column section)" % os.path.basename(path))
    return rows_to_bin(path, header, rows, fps or args.fps, args)


# Avid's own bin columns that Bin Diff can work out from an .avb file (named as in Avid).
AVB_COLUMNS = ["Name", "Duration", "Start", "End", "Tracks", "FPS", "Video", "Raster Dimension",
               "Image Aspect Ratio", "Audio SR", "Audio Bit Depth", "Color", "Soundroll", "Sound TC",
               "Source File", "Source Path", "Drive", "Creation Date", "Modified Date"]
# Bin-view entries that are never data columns (icon column, Name etc. handled above).
_VIEW_SKIP_TYPES = {200}


def _fmt_value(v) -> str:
    if v is None:
        return ""
    if isinstance(v, _dt.datetime):
        return v.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(v, (bytes, bytearray)):
        return ""
    return str(v).strip()


def _norm_key(s: str) -> str:
    """'Shoot Date', '_SHOOT_DATE', 'ShootDate' -> 'shootdate'."""
    return re.sub(r"[^0-9a-z]", "", str(s).lower())


def _readable_key(k) -> bool:
    """Skip Avid's scrambled internal keys (they aren't plain ASCII)."""
    s = str(k)
    return bool(s) and all(32 <= ord(ch) < 127 for ch in s)


def read_avb(path: str, args) -> Bin:
    try:
        import avb  # type: ignore
    except ImportError:
        raise SystemExit("Couldn't load the bundled pyavb library (vendor/avb is missing).\n"
                         "Export the bin from Avid as Tab Delimited / ALE and use that instead.")

    b = Bin(path)

    def comp_rate(comp) -> Optional[float]:
        r = getattr(comp, "edit_rate", None)
        try:
            return float(r) if r else None
        except (TypeError, ValueError):
            return None

    def media_kind(t):
        try:
            return t.component.media_kind
        except Exception:
            return None

    def ordered_tracks(mob):
        tracks = list(getattr(mob, "tracks", []) or [])
        return sorted(tracks, key=lambda t: {"picture": 0, "sound": 1}.get(media_kind(t), 2))

    def walk_clips(comp, depth=0):
        """Yield SourceClips found inside a component tree."""
        if comp is None or depth > 12:
            return
        if type(comp).__name__ == "SourceClip":
            yield comp
            return
        for attr in ("components", "tracks", "input_segment"):
            child = getattr(comp, attr, None)
            if child is None:
                continue
            for c in (child if isinstance(child, (list, tuple)) or hasattr(child, "__iter__") else [child]):
                yield from walk_clips(getattr(c, "component", c), depth + 1)

    def timecode_of(tape_mob):
        for t in getattr(tape_mob, "tracks", []) or []:
            comp = getattr(t, "component", None)
            for c in [comp] + list(getattr(comp, "components", []) or []):
                if type(c).__name__ == "Timecode":
                    return c
        return None

    def source_chain(mob, kind: Optional[str]):
        """Mobs behind a clip for one kind of track ('picture', 'sound', or None = first
        track of any kind), nearest first, each with its offset into that mob."""
        out, seen, offset, cur = [], {id(mob)}, 0, mob
        for _ in range(8):
            nxt = None
            tracks = ordered_tracks(cur)
            if kind:
                tracks = [t for t in tracks if media_kind(t) == kind] or ([] if cur is mob else tracks)
            for t in tracks:
                for sc in walk_clips(t.component):
                    try:
                        ref = sc.mob
                        start = int(getattr(sc, "start_time", 0) or 0)
                    except Exception:
                        ref, start = None, 0
                    if ref is not None and id(ref) not in seen:
                        nxt = (ref, offset + start)
                    break
                if nxt:
                    break
            if not nxt:
                break
            seen.add(id(nxt[0]))
            out.append(nxt)
            cur, offset = nxt
        return out

    def tape_in(chain):
        """(tape name, start TC string or '') for the first tape mob in a chain."""
        for m, off in chain:
            desc = getattr(m, "descriptor", None)
            if desc is not None and type(desc).__name__ == "TapeDescriptor":
                tc = timecode_of(m)
                try:
                    if tc is not None and int(tc.fps or 0) > 0:
                        return m.name, (int(tc.start or 0) + off, int(tc.fps), bool(int(tc.flags or 0) & 1))
                except Exception:
                    pass
                return m.name, None
        return None, None

    def descriptors(m):
        d = getattr(m, "descriptor", None)
        if d is None:
            return []
        out = [d]
        for sub in getattr(d, "descriptors", None) or []:      # MultiDescriptor
            out.append(sub)
        return out

    def picture_info(chain) -> Dict[str, str]:
        info = {}
        for m, _ in chain:
            for d in descriptors(m):
                try:
                    w, h = getattr(d, "stored_width", None), getattr(d, "stored_height", None)
                    if w and h and "Raster Dimension" not in info:
                        info["Raster Dimension"] = "%dx%d" % (int(w), int(h))
                    ar = getattr(d, "aspect_ratio", None)
                    if ar and "Image Aspect Ratio" not in info:
                        try:
                            num, den = ar.numerator, ar.denominator
                        except AttributeError:
                            num, den = (ar[0], ar[1]) if isinstance(ar, (list, tuple)) else (float(ar), 1)
                        if den:
                            info["Image Aspect Ratio"] = "%d:%d" % (num, den) if float(num).is_integer() else "%.2f" % (num / den)
                    rid = getattr(d, "resolution_id", None)
                    if rid and "Video" not in info:
                        info["Video"] = resolution_names.get(int(rid), "Resolution %d" % int(rid))
                except Exception:
                    pass
        return info

    def sound_info(chain) -> Dict[str, str]:
        info = {}
        for m, _ in chain:
            for d in descriptors(m):
                try:
                    sr = getattr(d, "sample_rate", None)
                    bits = getattr(d, "quantization_bits", None)
                    summary = getattr(d, "summary", None)
                    if (not sr or not bits) and isinstance(summary, (bytes, bytearray)) and type(d).__name__ == "WaveDescriptor":
                        raw = bytes(summary)
                        i = raw.find(b"fmt ")
                        fmt = raw[i + 8:] if i >= 0 else raw
                        if len(fmt) >= 16:
                            import struct
                            _, _, rate, _, _, depth = struct.unpack("<HHIIHH", fmt[:16])
                            sr, bits = sr or rate, bits or depth
                    if sr and "Audio SR" not in info and float(sr) >= 1000:
                        info["Audio SR"] = "%g" % float(sr)
                    if bits and "Audio Bit Depth" not in info:
                        info["Audio Bit Depth"] = str(int(bits))
                except Exception:
                    pass
        return info

    def locator_info(chains) -> Dict[str, str]:
        info = {}
        for chain in chains:
            for m, _ in chain:
                for d in descriptors(m):
                    locs = getattr(d, "locator", None)
                    if locs is None:
                        continue
                    if not isinstance(locs, (list, tuple)) and not hasattr(locs, "__iter__"):
                        locs = [locs]
                    try:
                        locs = list(locs)
                    except Exception:
                        locs = []
                    for loc in locs:
                        name = type(loc).__name__
                        try:
                            if name.endswith("FileLocator"):
                                p = (getattr(loc, "path_posix", None) or getattr(loc, "path_utf8", None)
                                     or getattr(loc, "path", None) or "")
                                if p and "Source Path" not in info:
                                    info["Source Path"] = str(p)
                                    info["Source File"] = os.path.basename(str(p).rstrip("/"))
                            elif name == "MSMLocator":
                                v = getattr(loc, "last_known_volume_utf8", None) or getattr(loc, "last_known_volume", None)
                                if v and "Drive" not in info:
                                    info["Drive"] = str(v)
                        except Exception:
                            pass
        return info

    def mob_rate(mob) -> Optional[float]:
        for t in ordered_tracks(mob):
            if media_kind(t) == "timecode":
                continue
            r = comp_rate(getattr(t, "component", None))
            if r:
                return r
        return None

    def tracks_label(mob) -> str:
        kinds = [media_kind(t) for t in getattr(mob, "tracks", []) or []]
        parts = []
        for kind, letter in (("picture", "V"), ("sound", "A")):
            n = kinds.count(kind)
            if n == 1:
                parts.append("%s1" % letter)
            elif n > 1:
                parts.append("%s1-%d" % (letter, n))
        return " ".join(parts)

    def attr_items(mob):
        try:
            attrs = mob.attributes
            return list(attrs.items()) if attrs else []
        except Exception:
            return []

    def user_columns(mob) -> "OrderedDict[str, str]":
        """Avid keeps custom bin columns (Comments, Lens, ...) in the clip's "_USER" list;
        other plain-named attributes are included too."""
        out = OrderedDict()
        for key, val in attr_items(mob):
            if key == "_USER":
                try:
                    for k, v in val.items():
                        if _readable_key(k) and not str(k).startswith("_"):
                            out[str(k)] = _fmt_value(v)
                except Exception:
                    pass
            elif _readable_key(key) and not str(key).startswith("_") and isinstance(val, (str, int)):
                out[str(key)] = _fmt_value(val)
        return out

    def all_attributes(mobs) -> Dict[str, str]:
        """Every readable string/number attribute on these mobs (and nested lists),
        keyed by normalised name -- nearest mob wins."""
        found = {}
        def visit(items, depth):
            for key, val in items:
                if not _readable_key(key):
                    continue
                if hasattr(val, "items") and not isinstance(val, (str, bytes, bytearray)) and depth < 3:
                    try:
                        visit(list(val.items()), depth + 1)
                    except Exception:
                        pass
                elif isinstance(val, (str, int, _dt.datetime)) and not isinstance(val, bool):
                    found.setdefault(_norm_key(key), _fmt_value(val))
        for m in mobs:
            visit(attr_items(m), 0)
        return found

    def clip_color(mob) -> str:
        a = dict(attr_items(mob))
        rgb = [a.get("_COLOR_R"), a.get("_COLOR_G"), a.get("_COLOR_B")]
        if all(isinstance(x, int) for x in rgb):
            if max(rgb) > 255:
                rgb = [x >> 8 for x in rgb]
            return "#%02X%02X%02X" % tuple(max(0, min(255, x)) for x in rgb)
        return ""

    with avb.open(path) as f:
        # The bin's own column list: which columns it shows, and the names of video
        # resolutions (Avid lists those as columns too, keyed by resolution ID).
        view_cols = []
        resolution_names = {}
        try:
            for c in f.content.view_setting.columns or []:
                title, ctype = (c.get("title") or "").strip(), c.get("type")
                if isinstance(ctype, int) and ctype >= 10000 and title:
                    resolution_names[ctype] = title
                elif title and ctype not in _VIEW_SKIP_TYPES:
                    view_cols.append((title, bool(c.get("hidden")), ctype))
        except Exception:
            pass

        items = list(f.content.items)
        # Bins also carry hidden "reference clips" (e.g. the master clips behind
        # a subclip). Those aren't user_placed; skip them like Avid's bin view does.
        visible = [it for it in items if getattr(it, "user_placed", True)]

        def is_clip(it):
            try:
                return it.mob.mob_type == "MasterMob" or (
                    it.mob.mob_type == "CompositionMob" and getattr(it.mob, "usage_code", None) == 2)
            except Exception:
                return False
        if not any(is_clip(it) for it in visible):
            visible = items

        user_cols = []
        for item in visible:
            mob = item.mob
            try:
                mtype = mob.mob_type
            except Exception:
                continue
            if mtype == "MasterMob":
                kind = "master"
            elif mtype == "CompositionMob" and getattr(mob, "usage_code", None) == 2:
                kind = "subclip"
            else:
                continue
            rate = mob_rate(mob) or args.fps
            try:
                length = int(mob.length)
            except Exception:
                length = None

            pic = source_chain(mob, "picture")
            snd = source_chain(mob, "sound")
            anyc = pic or snd or source_chain(mob, None)
            tape, start = tape_in(pic or anyc)
            sound_tape, sound_start = tape_in(snd)

            def tc_pair(st):
                if not st:
                    return "", ""
                sf, base, drop = st
                return (frames_to_clock_tc(sf, base, drop),
                        frames_to_clock_tc(sf + length, base, drop) if length is not None else "")
            start_s, end_s = tc_pair(start)

            meta = OrderedDict([
                ("Name", mob.name or ""),
                ("Duration", frames_to_tc(length, rate) if length is not None else ""),
                ("Start", start_s),
                ("End", end_s),
                ("Tracks", tracks_label(mob)),
                ("FPS", fmt_fps(rate)),
                ("Creation Date", _fmt_value(getattr(mob, "creation_time", None))),
                ("Modified Date", _fmt_value(getattr(mob, "last_modified", None))),
                ("Color", clip_color(mob)),
            ])
            meta.update(picture_info(pic or anyc))
            meta.update(sound_info(snd))
            meta.update(locator_info([pic, snd]))
            # Sync clips: the audio comes from its own sound roll.
            if sound_tape and tape and sound_tape != tape:
                meta["Soundroll"] = sound_tape
                meta["Sound TC"] = tc_pair(sound_start)[0]

            user = user_columns(mob)
            for k in user:
                if k not in user_cols:
                    user_cols.append(k)
            meta.update(user)

            # Columns the bin shows that we haven't filled yet: look for an attribute with
            # the same name anywhere on the clip or the media/tape behind it.
            have = {_norm_key(k) for k, v in meta.items() if v}
            if view_cols:
                attrs = all_attributes([mob] + [m for m, _ in pic + snd])
                for title, _, _ in view_cols:
                    k = _norm_key(title)
                    if k and k not in have and attrs.get(k):
                        meta[title] = attrs[k]
                        have.add(k)

            b.clips.append(Clip(name=mob.name or "(unnamed)", tape=tape or "", frames=length,
                                fps=rate, kind=kind, start_tc=start_s, meta=meta,
                                raw_duration=meta["Duration"]))

        # Columns: Avid's own ones that have a value somewhere in this bin, then the rest.
        filled = {}
        for c in b.clips:
            for k, v in c.meta.items():
                if v:
                    filled.setdefault(k.lower(), k)
        b.add_columns([c for c in AVB_COLUMNS if c.lower() in filled or c in ("Name", "Duration")])
        b.add_columns(user_cols)
        b.add_columns([t for t, _, _ in view_cols if t.lower() in filled])
        # Shown in the bin view, but no values found in the .avb file.
        got = {_norm_key(c) for c in b.columns} | {"tape"}
        b.unreadable = [t for t, hidden, _ in view_cols if not hidden and _norm_key(t) not in got]
    return b


def select_clip_kinds(b: Bin, include_subclips: bool) -> Bin:
    """Master clips only, unless subclips are requested -- or the bin has no
    master clips at all (e.g. an AutoSync bin full of sync subclips)."""
    masters = [c for c in b.clips if c.kind != "subclip"]
    subs = [c for c in b.clips if c.kind == "subclip"]
    if not subs or include_subclips or not masters:
        return b
    b.clips = masters
    return b


def load_bin(path: str, args, filter_kinds: bool = True) -> Bin:
    if not os.path.isfile(path):
        raise SystemExit("File not found: %s" % path)
    ext = os.path.splitext(path)[1].lower()
    if ext == ".avb":
        b = read_avb(path, args)
        return select_clip_kinds(b, args.include_subclips) if filter_kinds else b
    if ext == ".ale":
        return read_ale(path, args)
    head = _read_text(path)[:200].lower()
    if head.lstrip().startswith("heading"):
        return read_ale(path, args)
    return read_delimited(path, args)


# --------------------------------------------------------------------------- #
# Comparison
# --------------------------------------------------------------------------- #

@dataclass
class MetaDiff:
    pair: "Pair"
    column: str
    a: str
    b: str


@dataclass
class Pair:
    tape: str
    a: Clip
    b: Clip
    note: str = ""
    meta_diffs: List[MetaDiff] = field(default_factory=list)
    duration_flagged: bool = False

    @property
    def diff(self) -> Optional[int]:
        if self.a.frames is None or self.b.frames is None:
            return None
        return self.b.frames - self.a.frames

    @property
    def abs_seconds(self) -> float:
        return abs(self.diff or 0) / (self.a.fps or 24)

    @property
    def has_differences(self) -> bool:
        return self.duration_flagged or bool(self.meta_diffs)


@dataclass
class Result:
    a: Bin
    b: Bin
    pairs: List[Pair]
    only_a: List[Clip]
    only_b: List[Clip]
    no_tape_a: List[Clip]
    no_tape_b: List[Clip]
    dup_tapes: Dict[str, Tuple[int, int]]
    tolerance: int
    compared_columns: List[str]       # metadata columns compared (not Duration)
    compare_duration: bool
    columns_only_a: List[str]
    columns_only_b: List[str]
    ignored_columns: List[str]        # present in the bins but turned off

    @property
    def flagged(self) -> List[Pair]:
        """Duration differences, biggest first."""
        out = [p for p in self.pairs if p.duration_flagged]
        return sorted(out, key=lambda p: (-abs(p.diff), p.tape.lower()))

    @property
    def meta_diffs(self) -> List[MetaDiff]:
        order = {c.lower(): i for i, c in enumerate(self.compared_columns)}
        out = [d for p in self.pairs for d in p.meta_diffs]
        return sorted(out, key=lambda d: (order.get(d.column.lower(), 999), d.pair.a.name.lower()))

    @property
    def unknown(self) -> List[Pair]:
        return [p for p in self.pairs if p.diff is None] if self.compare_duration else []

    @property
    def matching(self) -> List[Pair]:
        return [p for p in self.pairs if not p.has_differences]

    @property
    def changed(self) -> List[Pair]:
        return [p for p in self.pairs if p.has_differences]

    def column_counts(self) -> "OrderedDict[str, int]":
        counts = OrderedDict()
        if self.compare_duration:
            counts["Duration"] = len(self.flagged)
        for c in self.compared_columns:
            counts[c] = 0
        for d in (d for p in self.pairs for d in p.meta_diffs):
            counts[d.column] = counts.get(d.column, 0) + 1
        return counts


def tape_key(tape: str, case_sensitive: bool) -> str:
    t = tape.strip()
    return t if case_sensitive else t.lower()


def group(clips: List[Clip], case_sensitive: bool):
    groups: "OrderedDict[str, List[Clip]]" = OrderedDict()
    no_tape = []
    for c in clips:
        if not c.tape.strip():
            no_tape.append(c)
            continue
        groups.setdefault(tape_key(c.tape, case_sensitive), []).append(c)
    return groups, no_tape


def _norm(v: str, ignore_case: bool) -> str:
    v = " ".join((v or "").split())
    return v.lower() if ignore_case else v


def compare(a: Bin, b: Bin, tolerance: int = 0, case_sensitive: bool = False,
            ignore_columns: Optional[Set[str]] = None, ignore_value_case: bool = False) -> Result:
    ignore = {c.strip().lower() for c in (ignore_columns or set()) if c.strip()}
    ga, nta = group(a.clips, case_sensitive)
    gb, ntb = group(b.clips, case_sensitive)
    pairs, only_a, only_b, dups = [], [], [], {}

    for key in list(ga.keys()) + [k for k in gb.keys() if k not in ga]:
        la, lb = list(ga.get(key, [])), list(gb.get(key, []))
        if len(la) > 1 or len(lb) > 1:
            dups[key] = (len(la), len(lb))
        note = "tape appears %d× in A, %d× in B" % (len(la), len(lb)) if key in dups else ""
        # Same tape used by several clips: pair identical clip names first, then the rest in order.
        for ca in list(la):
            match = next((cb for cb in lb if cb.name == ca.name), None)
            if match is not None and (len(la) > 1 or len(lb) > 1):
                pairs.append(Pair(ca.tape, ca, match, note))
                la.remove(ca)
                lb.remove(match)
        for ca, cb in zip(la, lb):
            pairs.append(Pair(ca.tape, ca, cb, note))
        only_a.extend(la[len(lb):])
        only_b.extend(lb[len(la):])

    cols_b = {c.lower() for c in b.columns}
    cols_a = {c.lower() for c in a.columns}
    shared = [c for c in a.columns if c.lower() in cols_b]
    compare_duration = "duration" not in ignore
    compared = [c for c in shared if c.lower() not in ignore and c.lower() != "duration"]
    ignored = [c for c in shared if c.lower() in ignore]

    for p in pairs:
        d = p.diff
        p.duration_flagged = compare_duration and d is not None and abs(d) > tolerance
        for col in compared:
            va, vb = p.a.value(col), p.b.value(col)
            if _norm(va, ignore_value_case) != _norm(vb, ignore_value_case):
                p.meta_diffs.append(MetaDiff(p, col, va, vb))

    return Result(a, b, pairs, only_a, only_b, nta, ntb, dups, tolerance,
                  compared, compare_duration,
                  [c for c in a.columns if c.lower() not in cols_b],
                  [c for c in b.columns if c.lower() not in cols_a],
                  ignored)


# --------------------------------------------------------------------------- #
# Report options
# --------------------------------------------------------------------------- #

# Shown by default (turn off with --hide): sections, then duration-table columns.
SECTIONS = ["paths", "summary", "by_column", "durations", "metadata", "columns",
            "only_a", "only_b", "no_tape", "same"]
COLUMNS = ["tape", "dur_a", "dur_b", "diff_tc", "diff_frames", "diff_sec", "direction", "magnitude"]
# Off by default (turn on with --show): extra duration-table columns.
EXTRAS = ["start_tc", "frames", "fps"]
# Sections that are off by default (turn on with --show).
OPTIONAL_SECTIONS = ["summary"]
REPORT_KEYS = SECTIONS + COLUMNS + EXTRAS


@dataclass
class ReportOptions:
    hide: Set[str] = field(default_factory=set)
    show: Set[str] = field(default_factory=set)

    def on(self, key: str) -> bool:
        if key in EXTRAS or key in OPTIONAL_SECTIONS:
            return key in self.show
        return key not in self.hide


def parse_keys(s: Optional[str]) -> Set[str]:
    keys = {k.strip() for k in (s or "").split(",") if k.strip()}
    bad = keys - set(REPORT_KEYS)
    if bad:
        raise SystemExit("Unknown report option(s): %s\nValid options: %s"
                         % (", ".join(sorted(bad)), ", ".join(REPORT_KEYS)))
    return keys


def split_list(s: Optional[str]) -> Set[str]:
    return {k.strip() for k in (s or "").split(",") if k.strip()}


# --------------------------------------------------------------------------- #
# CSV: one row per difference, then unmatched clips
# --------------------------------------------------------------------------- #

CSV_HEADERS = ["Clip (A)", "Clip (B)", "Tape", "Column", "Bin A", "Bin B", "Difference", "Status", "Note"]


def write_csv(res: Result, path: str, opts: ReportOptions = None):
    opts = opts or ReportOptions()
    rows = []
    if opts.on("durations"):
        for p in res.flagged:
            rows.append([p.a.name, p.b.name, p.tape, "Duration", dur_tc(p.a), dur_tc(p.b),
                         "%s (%+d fr)" % (signed_tc(p.diff, p.a.fps), p.diff),
                         "B longer" if p.diff > 0 else "B shorter", p.note])
    if opts.on("metadata"):
        for d in res.meta_diffs:
            p = d.pair
            rows.append([p.a.name, p.b.name, p.tape, d.column, d.a, d.b, "", "different", p.note])
    if opts.on("only_a"):
        rows += [[c.name, "", c.tape, "", "", "", "", "only in A", ""] for c in res.only_a]
    if opts.on("only_b"):
        rows += [["", c.name, c.tape, "", "", "", "", "only in B", ""] for c in res.only_b]
    if opts.on("no_tape"):
        rows += [[c.name, "", "", "", "", "", "", "no tape name (A)", ""] for c in res.no_tape_a]
        rows += [["", c.name, "", "", "", "", "", "no tape name (B)", ""] for c in res.no_tape_b]
    if opts.on("same"):
        rows += [[p.a.name, p.b.name, p.tape, "", "", "", "", "identical", p.note] for p in res.matching]
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(CSV_HEADERS)
        w.writerows(rows)


# --------------------------------------------------------------------------- #
# HTML report
# --------------------------------------------------------------------------- #

CSS = """
:root{--bg:#f6f6f4;--panel:#fff;--ink:#1d1d1f;--muted:#6b6b70;--line:#e3e3df;
--accent:#2f5bd3;--long:#b4541a;--short:#2a7a5a;--bar:#dfe6fb;--warn:#8a6a00;--warnbg:#fff6d9;
--olda:#f9e2dc;--newb:#dcefe4}
@media (prefers-color-scheme:dark){:root{--bg:#141416;--panel:#1d1d20;--ink:#ececee;--muted:#9a9aa2;
--line:#2e2e33;--accent:#7d9bff;--long:#f0965a;--short:#5fcf9f;--bar:#2a3352;--warn:#e9c75a;--warnbg:#2e2914;
--olda:#3a2420;--newb:#1d3327}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
main{max-width:1200px;margin:0 auto;padding:28px 16px 60px}
h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:32px 0 10px}
.sub{color:var(--muted);margin:0 0 20px}
.bins{display:grid;grid-template-columns:auto 1fr;gap:2px 10px;margin-bottom:20px;color:var(--muted)}
.bins b{color:var(--ink);font-weight:600;overflow-wrap:anywhere}
.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
@media (max-width:640px){.cards{grid-template-columns:repeat(2,1fr)}}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.card .n{font-size:24px;font-weight:650;font-variant-numeric:tabular-nums}
.card .l{color:var(--muted);font-size:12px}
.card.hot .n{color:var(--long)}
.card.dim{opacity:.35}
.wrap{overflow-x:auto;background:var(--panel);border:1px solid var(--line);border-radius:10px}
table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
th,td{padding:7px 10px;text-align:left;border-bottom:1px solid var(--line);white-space:nowrap}
td.wrapcell{white-space:normal;min-width:160px;max-width:420px;overflow-wrap:anywhere}
th{font-size:12px;color:var(--muted);font-weight:600;position:sticky;top:0;background:var(--panel);cursor:pointer;user-select:none}
tr:last-child td{border-bottom:0}
td.num,th.num{text-align:right}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px}
.long{color:var(--long)}.short{color:var(--short)}
.barcell{min-width:140px;width:40%}
.bar{height:8px;border-radius:4px;background:var(--accent);opacity:.8}
.note{color:var(--warn);font-size:12px}
.muted{color:var(--muted)}
.va{background:var(--olda)}.vb{background:var(--newb)}
.warnbox{background:var(--warnbg);color:var(--warn);border-radius:8px;padding:10px 12px;margin-top:12px}
.empty{padding:16px;color:var(--muted)}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{background:var(--panel);border:1px solid var(--line);border-radius:999px;padding:3px 10px;font-size:13px}
details{margin-top:8px}summary{cursor:pointer;color:var(--muted)}
footer{margin-top:48px;color:var(--muted);font-size:11px;opacity:.7}
.filter{margin:0 0 10px;padding:7px 10px;width:100%;max-width:320px;border:1px solid var(--line);border-radius:8px;background:var(--panel);color:var(--ink)}
.toolbar{display:flex;gap:8px;align-items:center;margin:0 0 10px}
.toolbar button{font:inherit;font-size:12px;padding:4px 10px;border:1px solid var(--line);border-radius:6px;background:var(--panel);color:var(--ink);cursor:pointer}
.toolbar .hint{color:var(--muted);font-size:12px}
#bycol tr.colrow{cursor:pointer}
#bycol tr.colrow.off td{opacity:.4}
#bycol td.cb{width:28px}
#bycol tr.grouprow td{font-size:12px;font-weight:600;color:var(--muted);padding-top:14px;background:var(--bg)}
#bycol input{width:16px;height:16px;cursor:pointer;accent-color:var(--accent)}
.colhidden{display:none!important}
h2 .count{font-weight:500;font-size:13px;color:var(--muted);margin-left:6px}
@media print{
  :root{--bg:#fff;--panel:#fff;--ink:#111;--muted:#666;--line:#ccc;--accent:#2f5bd3;--long:#a14a14;--short:#1f6b4c;
        --warn:#7a5d00;--warnbg:#fff6d9;--olda:#fbe7e1;--newb:#e2f2e8}
  *{-webkit-print-color-adjust:exact;print-color-adjust:exact}
  body{font-size:10.5px}
  main{max-width:none;padding:0}
  h1{font-size:18px}h2{font-size:13px;margin:18px 0 6px;break-after:avoid}
  .noprint,.filter,.toolbar,#bycol tr.off,#bycol td.cb,#bycol th.cb,details.zero{display:none!important}
  .wrap{overflow:visible;border-radius:4px}
  th{position:static}
  th,td{white-space:normal;padding:4px 6px}
  td.wrapcell{max-width:none}
  .mono{font-size:10px}
  .card{padding:6px 8px}.card .n{font-size:16px}
  tr,.card{break-inside:avoid}
  section.colsec{break-inside:avoid;page-break-inside:avoid}
  h2{page-break-after:avoid}
  footer{margin-top:20px}
}
"""

JS = """
(function(){
var body=document.body, unchecked=new Set();
try{JSON.parse(body.dataset.unchecked||'[]').forEach(function(c){unchecked.add(c)})}catch(e){}
function setText(id,v){var el=document.getElementById(id);if(el)el.textContent=v}
function apply(notify){
  document.querySelectorAll('#bycol tr.colrow').forEach(function(r){
    var on=!unchecked.has(r.dataset.col);r.classList.toggle('off',!on);
    var cb=r.querySelector('input');if(cb)cb.checked=on});
  var clips=new Set(),shownCols=0,shownMeta=0,secs=document.querySelectorAll('section.colsec');
  secs.forEach(function(sec){
    var on=!unchecked.has(sec.dataset.col);sec.classList.toggle('colhidden',!on);
    if(!on)return;shownCols++;
    sec.querySelectorAll('tbody tr').forEach(function(r){clips.add(r.dataset.pair);if(sec.dataset.col!=='duration')shownMeta++})});
  var durOn=!unchecked.has('duration');
  document.querySelectorAll('.card.c-dur').forEach(function(c){c.classList.toggle('dim',!durOn)});
  setText('n-meta',shownMeta);setText('n-clips',clips.size);
  var none=document.getElementById('all-hidden');if(none)none.classList.toggle('colhidden',shownCols>0||!secs.length);
  var list=Array.from(unchecked);body.dataset.unchecked=JSON.stringify(list);
  if(notify&&window.webkit&&webkit.messageHandlers&&webkit.messageHandlers.bindiff)
    webkit.messageHandlers.bindiff.postMessage({unchecked:list});
}
document.querySelectorAll('#bycol tr.colrow').forEach(function(r){
  r.addEventListener('click',function(){
    var c=r.dataset.col;if(unchecked.has(c))unchecked.delete(c);else unchecked.add(c);apply(true)})});
document.querySelectorAll('[data-act]').forEach(function(b){b.addEventListener('click',function(){
  document.querySelectorAll('#bycol tr.colrow').forEach(function(r){
    if(b.dataset.act==='all')unchecked.delete(r.dataset.col);else unchecked.add(r.dataset.col)});
  apply(true)})});
document.querySelectorAll('table.sortable').forEach(function(t){
  t.querySelectorAll('th').forEach(function(th,i){th.addEventListener('click',function(){
    var b=t.tBodies[0],rows=[].slice.call(b.rows),asc=th.dataset.asc!=='1';th.dataset.asc=asc?'1':'0';
    rows.sort(function(x,y){var a=x.cells[i].dataset.v||x.cells[i].textContent,c=y.cells[i].dataset.v||y.cells[i].textContent;
      var na=parseFloat(a),nc=parseFloat(c);if(!isNaN(na)&&!isNaN(nc))return asc?na-nc:nc-na;return asc?a.localeCompare(c):c.localeCompare(a)});
    rows.forEach(function(r){b.appendChild(r)});});});});
document.querySelectorAll('input.filter').forEach(function(f){f.addEventListener('input',function(){var q=f.value.toLowerCase();
  document.querySelectorAll('#'+f.dataset.table+' tbody tr').forEach(function(r){r.style.display=r.textContent.toLowerCase().indexOf(q)>-1?'':'none'})})});
window.binDiffSetUnchecked=function(list){unchecked=new Set(list||[]);apply(false)};
apply(false);
})();
"""


def e(s) -> str:
    return html.escape(str(s) if s is not None else "")


def _td(text, cls="", v=None) -> str:
    return "<td%s%s>%s</td>" % (" class='%s'" % cls if cls else "",
                                 " data-v='%s'" % e(v) if v is not None else "", text)


def _th(text, num=False, cls="") -> str:
    classes = " ".join(x for x in ("num" if num else "", cls) if x)
    return '<th%s>%s</th>' % (' class="%s"' % classes if classes else "", e(text))


def _table(head: List[str], rows: List[str], tid: str = "", sortable: bool = True) -> str:
    return ('<div class="wrap"><table %s%s><thead><tr>%s</tr></thead><tbody>%s</tbody></table></div>'
            % ('id="%s" ' % tid if tid else "", 'class="sortable"' if sortable else "",
               "".join(head), "".join(rows)))


def _filter(tid: str, placeholder: str) -> str:
    return '<input class="filter" data-table="%s" placeholder="%s">' % (tid, e(placeholder))


def _clip_name(p: Pair) -> str:
    name = "<b>%s</b>" % e(p.a.name)
    if p.b.name != p.a.name:
        name += "<br><span class='muted'>B: %s</span>" % e(p.b.name)
    return name


def col_key(name: str) -> str:
    return name.strip().lower()


def clip_table(clips: List[Clip], opts: ReportOptions) -> str:
    if not clips:
        return '<div class="empty">None</div>'
    head = [_th("Clip")]
    if opts.on("tape"): head.append(_th("Tape"))
    head.append(_th("Duration", True))
    if opts.on("start_tc"): head.append(_th("Start", True))
    if opts.on("frames"): head.append(_th("Frames", True))
    if opts.on("fps"): head.append(_th("FPS", True))
    rows = []
    for c in sorted(clips, key=lambda c: (c.name.lower(), c.tape.lower())):
        r = [_td(e(c.name))]
        if opts.on("tape"): r.append(_td(e(c.tape) or "—"))
        r.append(_td(e(dur_tc(c)) or "?", "mono num", c.frames))
        if opts.on("start_tc"): r.append(_td(e(c.start_tc) or "—", "mono num"))
        if opts.on("frames"): r.append(_td("" if c.frames is None else c.frames, "mono num", c.frames))
        if opts.on("fps"): r.append(_td(e(fmt_fps(c.fps)), "num", c.fps))
        rows.append("<tr>%s</tr>" % "".join(r))
    return _table(head, rows)


def duration_table(flagged: List[Pair], opts: ReportOptions, pair_ids: Dict[int, int]) -> str:
    if not flagged:
        return '<div class="wrap"><div class="empty">No duration differences.</div></div>'
    max_abs = max(abs(p.diff) for p in flagged) or 1
    head = [_th("Rank", True), _th("Clip")]
    if opts.on("tape"): head.append(_th("Tape"))
    if opts.on("dur_a"): head.append(_th("Duration A", True))
    if opts.on("dur_b"): head.append(_th("Duration B", True))
    if opts.on("start_tc"): head += [_th("Start A", True), _th("Start B", True)]
    if opts.on("frames"): head += [_th("Frames A", True), _th("Frames B", True)]
    if opts.on("fps"): head.append(_th("FPS", True))
    if opts.on("diff_tc"): head.append(_th("Diff (TC)", True))
    if opts.on("diff_frames"): head.append(_th("Diff (fr)", True))
    if opts.on("diff_sec"): head.append(_th("Diff (sec)", True))
    if opts.on("direction"): head.append(_th("B vs A"))
    if opts.on("magnitude"): head.append(_th("Magnitude"))

    rows = []
    for i, p in enumerate(flagged, 1):
        d = p.diff
        cls = "long" if d > 0 else "short"
        note = "<div class='note'>%s</div>" % e(p.note) if p.note else ""
        name = _clip_name(p) + ("" if opts.on("tape") else note)
        r = [_td(i, "num", i), _td(name)]
        if opts.on("tape"): r.append(_td(e(p.tape) + note))
        if opts.on("dur_a"): r.append(_td(e(dur_tc(p.a)), "mono num", p.a.frames))
        if opts.on("dur_b"): r.append(_td(e(dur_tc(p.b)), "mono num", p.b.frames))
        if opts.on("start_tc"):
            r += [_td(e(p.a.start_tc) or "—", "mono num"), _td(e(p.b.start_tc) or "—", "mono num")]
        if opts.on("frames"): r += [_td(p.a.frames, "mono num", p.a.frames), _td(p.b.frames, "mono num", p.b.frames)]
        if opts.on("fps"): r.append(_td(e(fmt_fps(p.a.fps)), "num", p.a.fps))
        if opts.on("diff_tc"): r.append(_td(e(signed_tc(d, p.a.fps)), "mono num " + cls, d))
        if opts.on("diff_frames"): r.append(_td("%+d" % d, "mono num " + cls, d))
        if opts.on("diff_sec"): r.append(_td("%.2fs" % p.abs_seconds, "num", "%.4f" % p.abs_seconds))
        if opts.on("direction"): r.append(_td("B %s" % ("longer" if d > 0 else "shorter"), cls))
        if opts.on("magnitude"):
            r.append(_td("<div class='bar' style='width:%.1f%%'></div>" % max(2.0, 100.0 * abs(d) / max_abs),
                         "barcell", abs(d)))
        rows.append("<tr data-pair='%d'>%s</tr>" % (pair_ids[id(p)], "".join(r)))
    filt = _filter("durations", "Filter by clip or tape name…") if len(rows) > 20 else ""
    return filt + _table(head, rows, "durations")


def column_section(col: str, diffs: List[MetaDiff], index: int, pair_ids: Dict[int, int]) -> str:
    """One column's differences: Clip | Bin A | Bin B."""
    rows = []
    for d in sorted(diffs, key=lambda d: d.pair.a.name.lower()):
        p = d.pair
        note = "<div class='note'>%s</div>" % e(p.note) if p.note else ""
        rows.append("<tr data-pair='%d'>%s%s%s</tr>" % (
            pair_ids[id(p)], _td(_clip_name(p) + note),
            _td(e(d.a) if d.a else "<span class='muted'>(empty)</span>", "wrapcell va"),
            _td(e(d.b) if d.b else "<span class='muted'>(empty)</span>", "wrapcell vb")))
    tid = "col-%d" % index
    filt = _filter(tid, "Filter…") if len(rows) > 20 else ""
    return section_html(col, len(diffs), filt + _table([_th("Clip"), _th("Bin A"), _th("Bin B")], rows, tid))


def section_html(col: str, n: int, body: str, sub: str = "") -> str:
    return ('<section class="colsec" data-col="%s"><h2>%s <span class="count">%d clip%s%s</span></h2>%s</section>'
            % (e(col_key(col)), e(col), n, "" if n == 1 else "s", e(sub), body))


def column_totals(res: Result) -> Dict[str, int]:
    """How many linked clips each column was compared on."""
    totals = {c: len(res.pairs) for c in res.compared_columns}
    if res.compare_duration:
        totals["Duration"] = sum(1 for p in res.pairs if p.diff is not None)
    return totals


def sorted_counts(res: Result) -> List[Tuple[str, int]]:
    """Columns ordered for the overview: ones where some clips match and some differ
    come first (most differences first); columns where every clip differs come after
    them, since that's usually expected (e.g. a name suffix on every sync clip)."""
    counts = list(res.column_counts().items())
    totals = column_totals(res)
    order = {c: i for i, (c, _) in enumerate(counts)}

    def every(cn):
        c, n = cn
        return n > 0 and n >= totals.get(c, 0) > 1
    return sorted(counts, key=lambda cn: (every(cn), -cn[1], order[cn[0]]))


def by_column_table(res: Result) -> str:
    counts = sorted_counts(res)
    if not counts:
        return '<div class="empty">No columns were compared.</div>'
    totals = column_totals(res)
    with_diffs = [(c, n) for c, n in counts if n]
    zero = [c for c, n in counts if not n]
    if not with_diffs:
        out = '<div class="wrap"><div class="empty">No differences in any of the %d compared columns.</div></div>' % len(counts)
    else:
        rows = []
        some = [(c, n) for c, n in with_diffs if not (n >= totals.get(c, 0) > 1)]
        every = [(c, n) for c, n in with_diffs if (c, n) not in some]

        def row(col, n):
            total = totals.get(col, 0) or n
            return "<tr class='colrow' data-col='%s'>%s%s%s%s</tr>" % (
                e(col_key(col)),
                _td("<input type='checkbox' checked aria-label='Show %s'>" % e(col), "cb"),
                _td("<b>%s</b>" % e(col)),
                _td("%d <span class='muted'>of %d</span>" % (n, total), "num", n),
                _td("<div class='bar' style='width:%.1f%%'></div>" % max(2.0, 100.0 * n / total), "barcell", n))
        rows += [row(c, n) for c, n in some]
        if every:
            rows.append("<tr class='grouprow'><td class='cb'></td><td colspan='3'>Different on every clip "
                        "<span class='muted'>— often expected, e.g. a renamed clip or a new date</span></td></tr>")
            rows += [row(c, n) for c, n in every]
        out = ('<div class="toolbar"><button data-act="all">Show all</button><button data-act="none">Hide all</button>'
               '<span class="hint">Tick the columns you want to see — the report below updates to match.</span></div>'
               + _table([_th("", cls="cb"), _th("Column"), _th("Clips that differ", True), _th("")], rows,
                        "bycol", sortable=False))
    if zero:
        out += ('<details class="zero"><summary>%d compared column%s with no differences</summary>'
                '<div style="margin-top:8px">%s</div></details>' % (len(zero), "" if len(zero) == 1 else "s", _chips(zero)))
    return out


def unreadable_columns(res: "Result") -> List[str]:
    """Columns the bins' view shows that have no values in either .avb file."""
    have = {c.lower() for c in res.a.columns + res.b.columns}
    out = []
    for c in res.a.unreadable + res.b.unreadable:
        if c.lower() not in have and c not in out:
            out.append(c)
    return out


def unreadable_html(res: "Result") -> str:
    cols = unreadable_columns(res)
    if not cols:
        return ""
    return ("<p class='muted'>Shown in the bin, but no values found in the .avb file — "
            "Avid may keep these with the media rather than in the bin. To compare them, "
            "export both bins from Avid as Tab Delimited text and compare those:</p>%s" % _chips(cols))


def _chips(items: List[str]) -> str:
    if not items:
        return '<span class="muted">None</span>'
    return '<div class="chips">%s</div>' % "".join('<span class="chip">%s</span>' % e(i) for i in items)


def write_html(res: Result, path: str, opts: ReportOptions = None, unchecked: Optional[Set[str]] = None):
    opts = opts or ReportOptions()
    flagged = res.flagged
    pair_ids = {id(p): i for i, p in enumerate(res.pairs)}
    rank = {col_key(c): i for i, (c, _) in enumerate(sorted_counts(res))}
    meta = sorted(res.meta_diffs, key=lambda d: (rank.get(col_key(d.column), 999), d.pair.a.name.lower()))
    fps_set = sorted({c.fps for c in res.a.clips + res.b.clips})

    warnings = []
    if len(fps_set) > 1:
        warnings.append("Clips use more than one frame rate (%s fps). Frame differences are counted at each clip's own rate."
                        % ", ".join(fmt_fps(x) for x in fps_set))
    if res.dup_tapes:
        warnings.append("%d tape name(s) are used by more than one clip in a bin. Those clips were paired by identical clip name "
                        "first, then in bin order — check rows marked with a note." % len(res.dup_tapes))
    if res.unknown:
        warnings.append("%d matched clip(s) had a duration that couldn't be read: %s"
                        % (len(res.unknown), ", ".join(e(p.tape) for p in res.unknown[:20])))
    warn_html = "".join('<div class="warnbox">%s</div>' % w for w in warnings)

    parts = []
    show_path = (lambda b: b.path) if opts.on("paths") else (lambda b: b.label)
    parts.append('<div class="bins"><span>A</span><b>%s</b><span>B</span><b>%s</b></div>'
                 % (e(show_path(res.a)), e(show_path(res.b))))

    def card(label, value, cls="", vid=None):
        return '<div class="card %s"><div class="n"%s>%s</div><div class="l">%s</div></div>' % (
            cls, ' id="%s"' % vid if vid else "", e(value), e(label))

    if opts.on("summary"):
        biggest = flagged[0] if flagged else None
        cards = [card("Clips in A", len(res.a.clips)), card("Clips in B", len(res.b.clips)),
                 card("Matched by tape", len(res.pairs)),
                 card("Clips with differences", len(res.changed), "hot" if res.changed else "", "n-clips")]
        if res.compare_duration:
            cards += [card("Duration differences", len(flagged), "c-dur " + ("hot" if flagged else "")),
                      card("Biggest duration difference", signed_tc(biggest.diff, biggest.a.fps) if biggest else "—",
                           "c-dur " + ("hot" if biggest else ""))]
        cards += [card("Metadata differences", len(meta), "hot" if meta else "", "n-meta"),
                  card("Columns compared", len(res.compared_columns) + (1 if res.compare_duration else 0)),
                  card("Only in A", len(res.only_a)), card("Only in B", len(res.only_b))]
        if res.no_tape_a or res.no_tape_b:
            cards.append(card("No tape name (A / B)", "%d / %d" % (len(res.no_tape_a), len(res.no_tape_b)), "hot"))
        parts.append('<div class="cards">%s</div>' % "".join(cards))
    parts.append(warn_html)

    if opts.on("by_column"):
        parts.append("<h2>Differences by column</h2>%s" % by_column_table(res))
    # One section per column with differences, in the same order as the overview.
    by_col: "OrderedDict[str, List[MetaDiff]]" = OrderedDict()
    for d in meta:
        by_col.setdefault(d.column, []).append(d)
    sections = []
    for i, (col, n) in enumerate(sorted_counts(res)):
        if not n:
            continue
        if col == "Duration" and res.compare_duration:
            if opts.on("durations"):
                sections.append(section_html("Duration", len(flagged), duration_table(flagged, opts, pair_ids),
                                             " · largest difference first"))
        elif opts.on("metadata") and col in by_col:
            sections.append(column_section(col, by_col[col], i, pair_ids))
    parts.extend(sections)
    if sections:
        parts.append('<div id="all-hidden" class="wrap empty colhidden">All columns with differences are hidden. '
                     'Tick them in “Differences by column” to show them.</div>')
    if opts.on("columns"):
        # Shown in the app and browser, left out of PDFs and printouts.
        parts.append("<section class='noprint'><h2>Columns not compared</h2>"
                     "<p class='muted'>Only in bin A:</p>%s<p class='muted'>Only in bin B:</p>%s"
                     "<p class='muted'>Turned off in settings:</p>%s%s</section>"
                     % (_chips(res.columns_only_a), _chips(res.columns_only_b), _chips(res.ignored_columns),
                        unreadable_html(res)))
    if opts.on("only_a"):
        parts.append("<h2>Only in A (%d)</h2>%s" % (len(res.only_a), clip_table(res.only_a, opts)))
    if opts.on("only_b"):
        parts.append("<h2>Only in B (%d)</h2>%s" % (len(res.only_b), clip_table(res.only_b, opts)))
    if opts.on("no_tape") and (res.no_tape_a or res.no_tape_b):
        parts.append("<h2>No tape name in A — not compared (%d)</h2>%s" % (len(res.no_tape_a), clip_table(res.no_tape_a, opts)))
        parts.append("<h2>No tape name in B — not compared (%d)</h2>%s" % (len(res.no_tape_b), clip_table(res.no_tape_b, opts)))
    if opts.on("same"):
        if res.matching:
            head = [_th("Clip")] + ([_th("Tape")] if opts.on("tape") else []) + [_th("Duration", True)]
            rows = []
            for p in sorted(res.matching, key=lambda p: p.a.name.lower()):
                r = [_td(e(p.a.name))] + ([_td(e(p.tape))] if opts.on("tape") else [])
                r.append(_td(e(dur_tc(p.a)), "mono num", p.a.frames))
                rows.append("<tr>%s</tr>" % "".join(r))
            same = ('<details><summary>Show %d clip(s)</summary><div style="margin-top:8px">%s</div></details>'
                    % (len(res.matching), _table(head, rows)))
        else:
            same = '<div class="empty">None</div>'
        parts.append("<h2>Identical in every compared column (%d)</h2>%s" % (len(res.matching), same))

    notes = []
    if res.tolerance and res.compare_duration:
        notes.append("Duration differences of %d frame(s) or less are ignored." % res.tolerance)
    doc = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>%s report</title><style>%s</style></head>
<body data-unchecked='%s'><main>
<h1>Bin comparison report</h1>
<p class="sub">Clips are linked by tape name; every other shared column is compared. Generated %s. %s</p>
%s
<footer>%s</footer>
</main><script>%s</script></body></html>""" % (
        APP_NAME, CSS, e(json.dumps(sorted(col_key(c) for c in (unchecked or set())))),
        e(_dt.datetime.now().strftime("%Y-%m-%d %H:%M")), e(" ".join(notes)),
        "\n".join(parts), APP_NAME, JS)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(doc)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def print_summary(res: Result):
    flagged = res.flagged
    print("A: %s  (%d clips)" % (res.a.path, len(res.a.clips)))
    print("B: %s  (%d clips)" % (res.b.path, len(res.b.clips)))
    print("Matched by tape: %d   With differences: %d   Only in A: %d   Only in B: %d   No tape: %d/%d"
          % (len(res.pairs), len(res.changed), len(res.only_a), len(res.only_b),
             len(res.no_tape_a), len(res.no_tape_b)))
    if flagged:
        print("\nDuration differences, largest first (B - A):")
        wn = max(len(p.a.name) for p in flagged)
        wt = max(len(p.tape) for p in flagged)
        for i, p in enumerate(flagged, 1):
            print("  %3d. %-*s  %-*s  %13s  %+6d fr   %s -> %s" % (
                i, wn, p.a.name, wt, p.tape, signed_tc(p.diff, p.a.fps),
                p.diff, dur_tc(p.a), dur_tc(p.b)))
    meta = res.meta_diffs
    if meta:
        print("\nMetadata differences:")
        for d in meta:
            print("  %s [%s]  %s:  %r -> %r" % (d.pair.a.name, d.pair.tape, d.column, d.a, d.b))
    not_compared = res.columns_only_a + res.columns_only_b
    if not_compared:
        print("\nColumns in only one bin (not compared): %s" % ", ".join(not_compared))
    unread = unreadable_columns(res)
    if unread:
        print("\nShown in the bin but no values in the .avb file: %s" % ", ".join(unread))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Compare two Avid bins, linking clips by tape name.")
    ap.add_argument("bin_a", help="First bin (.avb, .ale, or tab-delimited export)")
    ap.add_argument("bin_b", help="Second bin")
    ap.add_argument("-o", "--output", help="HTML report path (default: <A>_vs_<B>_bindiff.html next to bin A)")
    ap.add_argument("--fps", type=float, default=24.0,
                    help="Frame rate for text exports that don't state one (default 24). .avb/.ale carry their own.")
    ap.add_argument("--tolerance", type=int, default=0, help="Ignore duration differences of this many frames or fewer")
    ap.add_argument("--ignore-columns", metavar="NAMES", help='Comma-separated columns not to compare, e.g. "Modified Date,Comments"')
    ap.add_argument("--ignore-value-case", action="store_true", help="Treat metadata values that differ only in upper/lower case as equal")
    ap.add_argument("--include-subclips", action="store_true", help=".avb only: also compare subclips. By default only master clips are "
                         "compared, except in a bin with no master clips, where its subclips are used.")
    ap.add_argument("--case-sensitive", action="store_true", help="Treat tape names with different case as different tapes")
    ap.add_argument("--tape-column", help="Column name to use as the tape name in text exports")
    ap.add_argument("--duration-column", help="Column name to use as the duration in text exports")
    ap.add_argument("--no-csv", action="store_true", help="Don't write the CSV alongside the HTML report")
    ap.add_argument("--hide", metavar="KEYS", help="Comma-separated report parts to leave out. Sections: %s. "
                    "Duration table columns: %s." % (", ".join(SECTIONS), ", ".join(COLUMNS)))
    ap.add_argument("--show", metavar="KEYS", help="Comma-separated extras to add: %s (duration table), summary (boxes at the top)." % ", ".join(EXTRAS))
    ap.add_argument("--unchecked", metavar="NAMES", help="Comma-separated columns to start unticked (hidden) in the report's column list")
    ap.add_argument("--open", action="store_true", help="Open the report in your browser when done")
    ap.add_argument("--json", action="store_true", help=argparse.SUPPRESS)  # used by the Mac app
    args = ap.parse_args(argv)
    opts = ReportOptions(hide=parse_keys(args.hide), show=parse_keys(args.show))

    a, b = load_bin(args.bin_a, args), load_bin(args.bin_b, args)
    res = compare(a, b, args.tolerance, args.case_sensitive,
                  split_list(args.ignore_columns), args.ignore_value_case)

    out = args.output
    if not out:
        stem = lambda p: os.path.splitext(os.path.basename(p))[0]
        out = os.path.join(os.path.dirname(os.path.abspath(args.bin_a)),
                           "%s_vs_%s_bindiff.html" % (stem(args.bin_a), stem(args.bin_b)))
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    write_html(res, out, opts, split_list(args.unchecked))
    csv_path = None
    if not args.no_csv:
        csv_path = os.path.splitext(out)[0] + ".csv"
        write_csv(res, csv_path, opts)
    if args.json:
        flagged = res.flagged
        top = flagged[0] if flagged else None
        all_cols = list(a.columns) + [c for c in b.columns if c.lower() not in {x.lower() for x in a.columns}]
        print(json.dumps({
            "differences": len(flagged), "matched": len(res.pairs),
            "clips_with_differences": len(res.changed), "metadata_differences": len(res.meta_diffs),
            "only_a": len(res.only_a), "only_b": len(res.only_b),
            "no_tape_a": len(res.no_tape_a), "no_tape_b": len(res.no_tape_b),
            "biggest_clip": top.a.name if top else None,
            "biggest_tc": signed_tc(top.diff, top.a.fps) if top else None,
            "biggest_frames": top.diff if top else None,
            "columns": all_cols,
            "columns_only_a": res.columns_only_a, "columns_only_b": res.columns_only_b,
            "report": os.path.abspath(out), "csv": csv_path and os.path.abspath(csv_path),
            "bin_a": a.label, "bin_b": b.label,
            "unreadable_columns": unreadable_columns(res),
        }))
    else:
        print_summary(res)
        print("\nReport: %s" % out)
        if csv_path:
            print("CSV:    %s" % csv_path)
    if args.open:
        webbrowser.open("file://" + os.path.abspath(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
