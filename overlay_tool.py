"""
overlay_tool.py — 保护 Godot 导出 exe 尾部的内嵌 PCK。

问题背景
--------
Godot 在 `binary_format/embed_pck=true` 时，会把整个 .pck 追加到 exe 文件
末尾（overlay），并在最后 12 字节写上

    [pck_size : u64 小端][magic : "GDPC"]

Godot 启动时用 `filesize - 12 - pck_size` 反推出 pck 起点。

而 rcedit 2.0.0 在改写 PE 资源时**不保留 overlay**：它把文件在 PE 末尾处
截断，然后补零到原来的长度。结果就是文件体积不变、图标和版本号都注入
成功了，但游戏一启动就报

    Error: Couldn't load project data at path "."
           Is the .pck file missing?

这个坑的阴险之处在于：构建脚本自己回读 FileVersion 是成功的，图标 6/6
也在，只有真正跑一次 exe 才会暴露。

解决办法
--------
在 rcedit 之前把 overlay 整段抠出来存盘，rcedit 之后再原样贴回去。
贴回时必须确认新的 PE 没有长过原来的 pck 起点，否则会把 PE 切掉一块。

用法
----
    python overlay_tool.py save    <exe> <out.bin>      # 抠出 overlay
    python overlay_tool.py restore <exe> <bin> <offset> # 贴回 overlay
    python overlay_tool.py check   <exe>                # 校验 overlay 完整
"""

import os
import struct
import sys

MAGIC = b"GDPC"
FOOTER_SIZE = 12


def read_all(path):
    with open(path, "rb") as f:
        return f.read()


def find_magic_offsets(data):
    offs = []
    i = 0
    while True:
        j = data.find(MAGIC, i)
        if j < 0:
            break
        offs.append(j)
        i = j + 1
    return offs


def locate(data):
    """返回 (pck_start, pck_size)。失败抛 ValueError。"""
    n = len(data)
    if n < FOOTER_SIZE:
        raise ValueError("文件太小，不可能是 Godot 导出产物")
    if data[-4:] != MAGIC:
        raise ValueError("文件末尾没有 GDPC 尾标记（overlay 已被破坏？）")

    size = struct.unpack_from("<Q", data, n - FOOTER_SIZE)[0]
    start = n - FOOTER_SIZE - size
    if start <= 0 or start >= n - FOOTER_SIZE:
        raise ValueError("解析出的 pck 起点越界: start=%d size=%d" % (start, size))
    if data[start:start + 4] != MAGIC:
        raise ValueError("pck 起点 %d 处没有 PACK 头，footer 解析可能有误" % start)

    # 与 PE 里 "pck" 节交叉验证；两者都指同一个位置才算数
    sec_ptr, sec_size = pck_section(data)
    if sec_ptr != start:
        raise ValueError('footer 推出的起点 %d 与 "pck" 节声明的 %d 不一致'
                         % (start, sec_ptr))
    if sec_size != size + FOOTER_SIZE:
        raise ValueError('"pck" 节大小 %d 与 footer 推出的 %d 不一致'
                         % (sec_size, size + FOOTER_SIZE))
    return start, size


def _sections(data):
    """解析 PE 节表，返回 [(name, virt_size, raw_ptr, raw_size), ...]。"""
    if data[:2] != b"MZ":
        raise ValueError("不是 PE 文件")
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if data[e_lfanew:e_lfanew + 4] != b"PE\x00\x00":
        raise ValueError("PE 签名不对")
    coff = e_lfanew + 4
    nsec = struct.unpack_from("<H", data, coff + 2)[0]
    size_opt = struct.unpack_from("<H", data, coff + 16)[0]
    sect = coff + 20 + size_opt

    out = []
    for i in range(nsec):
        off = sect + i * 40
        name = data[off:off + 8].rstrip(b"\x00").decode("latin1")
        virt_size = struct.unpack_from("<I", data, off + 8)[0]
        raw_size = struct.unpack_from("<I", data, off + 16)[0]
        raw_ptr = struct.unpack_from("<I", data, off + 20)[0]
        out.append((name, virt_size, raw_ptr, raw_size))
    return out


def pck_section(data):
    """
    Godot 的 embed_pck 会额外建一个名为 "pck" 的节专门放内嵌包，
    RawSize = pck 大小 + 12 字节 footer。这是定位 overlay 最可靠的方式。
    """
    for name, _vs, ptr, size in _sections(data):
        if name == "pck":
            return ptr, size
    raise ValueError('PE 里没有名为 "pck" 的节（embed_pck 可能已关闭）')


def pe_end(data):
    """
    从 PE 头算出有意义数据的结束位置（最后一个节的 RawData 末尾）。
    用来确认 rcedit 之后的 PE 没有长过 pck 起点。

    必须排除 "pck" 节：它的 RawSize 覆盖了整个 overlay，算进去的话
    pe_end 永远等于文件长度，这个守卫就失效了。
    """
    end = 0
    for name, _vs, ptr, size in _sections(data):
        if name == "pck":
            continue
        if size:
            end = max(end, ptr + size)
    return end


def cmd_save(exe, out):
    data = read_all(exe)
    start, size = locate(data)
    blob = data[start:]
    with open(out, "wb") as f:
        f.write(blob)
    print("OFFSET=%d" % start)
    print("SIZE=%d" % size)
    print("OVERLAY=%d" % len(blob))
    return 0


def cmd_restore(exe, bin_path, offset):
    blob = read_all(bin_path)
    offset = int(offset)
    with open(exe, "r+b") as f:
        f.seek(0, os.SEEK_END)
        cur = f.tell()
        if cur < offset:
            # 文件比 offset 还短，先把中间补零
            f.seek(cur)
            f.write(b"\x00" * (offset - cur))
        # 安全校验：PE 不能长过 overlay 起点，否则贴回去会把 PE 切掉
        f.seek(0)
        head = f.read(min(offset, 64 * 1024 * 1024))
        end = pe_end(head)
        if end > offset:
            print("[ERROR] PE 结束位置 %d 超过了 overlay 起点 %d，"
                  "贴回会破坏可执行文件。请改用分离式 pck。" % (end, offset))
            return 1
        f.seek(offset)
        f.write(blob)
        f.truncate(offset + len(blob))
    print("RESTORED=%d" % (offset + len(blob)))
    return 0


def cmd_check(exe):
    data = read_all(exe)
    start, size = locate(data)
    end = pe_end(data)
    print("FILE_SIZE=%d" % len(data))
    print("PCK_START=%d" % start)
    print("PCK_SIZE=%d" % size)
    print("PE_END=%d" % end)
    ok = end <= start
    print("PE_FITS=%s" % ("YES" if ok else "NO"))
    if not ok:
        print("[ERROR] PE 已经长过 PCK 起点，overlay 已被破坏")
        return 1
    print("[OK] 内嵌 PCK 完整 (%.1f KB)" % (size / 1024.0))
    return 0


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    try:
        if cmd == "save":
            return cmd_save(sys.argv[2], sys.argv[3])
        if cmd == "restore":
            return cmd_restore(sys.argv[2], sys.argv[3], sys.argv[4])
        if cmd == "check":
            return cmd_check(sys.argv[2])
    except ValueError as e:
        print("[ERROR] %s" % e)
        return 1
    except (OSError, struct.error) as e:
        print("[ERROR] 读写失败: %s" % e)
        return 1
    print("未知命令: %s" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main())
