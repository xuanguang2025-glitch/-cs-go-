"""
verify_exe.py — 校验 PROJECT_STRIKE.exe 的图标与版本信息注入结果。

为什么需要这个脚本：
  Godot 自定义构建在导出时的 rcedit 步骤会静默失败（它在 savepack 之前
  就对还不存在的 .tmp 文件调用 rcedit，错误信息写到了 Godot 不读的 stderr）。
  所以图标/版本信息实际是由 build_release.ps1 的第 3 步补注入的。
  这里独立复核，不信任构建脚本自己的回读。

校验项：
  1. icon/game.ico 里的每一个尺寸的 PNG 数据，都要能在 exe 里原样找到
  2. 版本字符串 FileVersion / ProductVersion 等是否写入
"""

import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXE = os.path.join(HERE, "build", "PROJECT_STRIKE.exe")
ICO = os.path.join(HERE, "icon", "game.ico")


def parse_ico(path):
    """解析 .ico，返回 [(width, height, png_bytes), ...]。"""
    data = open(path, "rb").read()
    if data[:4] != b"\x00\x00\x01\x00":
        raise SystemExit("不是合法的 ICO 文件: %s" % path)
    count = struct.unpack_from("<H", data, 4)[0]
    out = []
    for i in range(count):
        off = 6 + i * 16
        w = data[off] or 256
        h = data[off + 1] or 256
        size = struct.unpack_from("<I", data, off + 8)[0]
        start = struct.unpack_from("<I", data, off + 12)[0]
        out.append((w, h, data[start:start + size]))
    return out


def main():
    if not os.path.exists(EXE):
        raise SystemExit("找不到 %s" % EXE)

    exe = open(EXE, "rb").read()
    print("exe : %s" % EXE)
    print("size: %.1f MB" % (len(exe) / 1024 / 1024))

    # --- 1. 图标 ---
    print("\n[图标]")
    entries = parse_ico(ICO)
    hit = 0
    for w, h, blob in entries:
        found = exe.find(blob) >= 0
        hit += 1 if found else 0
        print("  %3dx%-3d  %6d bytes   %s"
              % (w, h, len(blob), "OK" if found else "缺失"))
    print("  小计: %d/%d" % (hit, len(entries)))

    # --- 2. 版本信息 ---
    print("\n[版本信息]")
    # VS_VERSION_INFO 里的字符串以 UTF-16LE 存放
    checks = {
        "CompanyName": "PROJECT STRIKE",
        "FileDescription": "PROJECT STRIKE - 5v5 Tactical FPS",
        "ProductName": "PROJECT STRIKE",
        "LegalCopyright": "Copyright (c) 2026 PROJECT STRIKE",
        "OriginalFilename": "PROJECT_STRIKE.exe",
        "FileVersion": "1.1.0.0",
        "ProductVersion": "1.1.0.0",
    }
    vhit = 0
    for key, val in checks.items():
        blob = val.encode("utf-16-le")
        found = exe.find(blob) >= 0
        vhit += 1 if found else 0
        print("  %-16s %-38s %s" % (key, val, "OK" if found else "缺失"))
    print("  小计: %d/%d" % (vhit, len(checks)))

    # --- 3. Steam 运行时 ---
    print("\n[Steamworks 运行时]")
    for name in ("steam_api64.dll", "steam_appid.txt"):
        p = os.path.join(HERE, "build", name)
        ok = os.path.exists(p)
        extra = ""
        if ok and name.endswith(".txt"):
            extra = " -> appid=%s" % open(p).read().strip()
        print("  %-18s %s%s" % (name, "OK" if ok else "缺失", extra))

    ok_all = (hit == len(entries)) and (vhit == len(checks))
    print("\n结论: %s" % ("全部通过" if ok_all else "有缺失项，见上"))
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
