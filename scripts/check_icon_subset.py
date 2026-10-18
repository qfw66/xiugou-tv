"""校验 Release 产物里的图标字体子集是否覆盖 lib/ 引用的全部图标。

背景（2026-10-18 实机事故）：`flutter build windows --release` 默认启用
--tree-shake-icons，会把 MaterialIcons-Regular.otf 裁剪成只含「源码里用到的
const IconData」的子集。增量构建曾复用旧子集，导致新增图标在运行时渲染成空白
（本次 7 个：上一集/下一集/重播/音轨/视轨/画面比例/字幕关闭 OSD）。

用法：
    python scripts/check_icon_subset.py [--font PATH] [--lib DIR] [--icons-dart PATH]

退出码：
    0  子集覆盖全部引用图标
    1  存在缺失图标（构建应失败）
    2  无法校验（缺少字体 / 源码 / SDK icons.dart）
"""

import argparse
import os
from pathlib import Path
import re
import shutil
import struct
import sys

DEFAULT_FONT = "build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf"
SDK_ICONS = "packages/flutter/lib/src/material/icons.dart"


def find_icons_dart(explicit):
    if explicit:
        return Path(explicit)
    root = os.environ.get("FLUTTER_ROOT")
    if root:
        candidate = Path(root) / SDK_ICONS
        if candidate.exists():
            return candidate
    flutter = shutil.which("flutter")
    if flutter:
        candidate = Path(flutter).resolve().parents[1] / SDK_ICONS
        if candidate.exists():
            return candidate
    return None


def load_tables(data):
    num_tables = struct.unpack(">H", data[4:6])[0]
    tables = {}
    for i in range(num_tables):
        offset = 12 + i * 16
        tag = data[offset:offset + 4].decode("latin1")
        tables[tag] = struct.unpack(">II", data[offset + 8:offset + 16])
    return tables


def read_cmap(data, cmap_offset):
    count = struct.unpack(">H", data[cmap_offset + 2:cmap_offset + 4])[0]
    codepoints = set()
    for i in range(count):
        record = cmap_offset + 4 + i * 8
        _pid, _eid, sub_offset = struct.unpack(">HHI", data[record:record + 8])
        base = cmap_offset + sub_offset
        fmt = struct.unpack(">H", data[base:base + 2])[0]
        if fmt == 4:
            seg = struct.unpack(">H", data[base + 6:base + 8])[0] // 2
            end_o = base + 14
            start_o = end_o + seg * 2 + 2
            delta_o = start_o + seg * 2
            range_o = delta_o + seg * 2
            for s in range(seg):
                end = struct.unpack(">H", data[end_o + s * 2:end_o + s * 2 + 2])[0]
                start = struct.unpack(">H", data[start_o + s * 2:start_o + s * 2 + 2])[0]
                delta = struct.unpack(">h", data[delta_o + s * 2:delta_o + s * 2 + 2])[0]
                range_offset = struct.unpack(">H", data[range_o + s * 2:range_o + s * 2 + 2])[0]
                if start == 0xFFFF:
                    continue
                for codepoint in range(start, end + 1):
                    if range_offset == 0:
                        glyph = (codepoint + delta) % 65536
                    else:
                        gi = range_o + s * 2 + range_offset + (codepoint - start) * 2
                        if gi + 2 > len(data):
                            continue
                        glyph = struct.unpack(">H", data[gi:gi + 2])[0]
                        if glyph:
                            glyph = (glyph + delta) % 65536
                    if glyph:
                        codepoints.add(codepoint)
        elif fmt == 12:
            groups = struct.unpack(">I", data[base + 12:base + 16])[0]
            for g in range(groups):
                start, end, _glyph = struct.unpack(
                    ">III", data[base + 16 + g * 12:base + 28 + g * 12])
                codepoints.update(range(start, end + 1))
    return codepoints


def load_font_codepoints(font_path):
    data = font_path.read_bytes()
    tables = load_tables(data)
    if "cmap" not in tables:
        raise ValueError("font has no cmap table")
    return read_cmap(data, tables["cmap"][0])


def load_icon_codepoints(icons_dart):
    content = icons_dart.read_text(encoding="utf-8")
    pattern = re.compile(
        r"static const IconData ([a-z0-9_]+) = IconData\(\s*0x([0-9a-fA-F]+)")
    return {m.group(1): int(m.group(2), 16) for m in pattern.finditer(content)}


def collect_usages(lib_dir):
    usage = {}
    pattern = re.compile(r"Icons\.([a-z0-9_]+)")
    for path in sorted(lib_dir.rglob("*.dart")):
        rel = path.as_posix()
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for match in pattern.finditer(line):
                usage.setdefault(match.group(1), []).append("%s:%d" % (rel, number))
    return usage


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--font", default=None)
    parser.add_argument("--lib", default=None)
    parser.add_argument("--icons-dart", default=None)
    parser.add_argument("--project-root", default=None)
    args = parser.parse_args(argv)

    project_root = Path(args.project_root or Path(__file__).resolve().parents[1])
    lib_dir = Path(args.lib) if args.lib else project_root / "lib"
    font_path = Path(args.font) if args.font else project_root / DEFAULT_FONT

    if not lib_dir.is_dir():
        print("ICON_SUBSET_SKIP 未找到源码目录：%s" % lib_dir)
        return 2
    if not font_path.is_file():
        print("ICON_SUBSET_ERROR 未找到图标字体：%s" % font_path)
        return 2
    icons_dart = find_icons_dart(args.icons_dart)
    if icons_dart is None:
        print("ICON_SUBSET_SKIP 未找到 Flutter SDK icons.dart（设置 FLUTTER_ROOT 后重试）")
        return 2

    width_by_name = load_icon_codepoints(icons_dart)
    present = load_font_codepoints(font_path)
    usage = collect_usages(lib_dir)

    missing = []
    unresolved = []
    for name in sorted(usage):
        codepoint = width_by_name.get(name)
        if codepoint is None:
            unresolved.append(name)
        elif codepoint not in present:
            missing.append((name, codepoint, usage[name][0]))

    total = len(usage)
    print("ICON_SUBSET_FONT %s (%d bytes, %d codepoints)"
          % (font_path, font_path.stat().st_size, len(present)))
    print("ICON_SUBSET_REFERENCED %d" % total)
    if unresolved:
        print("ICON_SUBSET_UNRESOLVED %d %s" % (len(unresolved), " ".join(unresolved)))
    if missing:
        print("ICON_SUBSET_MISSING %d" % len(missing))
        for name, codepoint, where in missing:
            print("  - %s (0x%x) first used at %s" % (name, codepoint, where))
        print("修复：删除 build/flutter_assets/fonts/MaterialIcons-Regular.otf 后重新构建。")
        return 1
    print("ICON_SUBSET_OK %d/%d" % (total, total))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
