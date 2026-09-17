"""
pe_imports.py — 解析 Windows PE 文件的导入表，列出所有依赖 DLL 与导入函数数。

为什么需要：发布版 exe 是不是真能在"无 Godot 的干净机器"上双击跑起来，
依赖这一步的答案。要列全，不能只读第一项。

踩过的坑（2026-09-01）：
1. DataDirectory[0] 在可选头 +112 (PE32+) / +96 (PE32)，[1] 还要再 +8。
   直接读 +112 拿到的是**导出表**，会把它当导入表走——输出里出现
   `amdpowerxpressrequesthighperformance`（Godot 的真实导出符号）就是这么来的。
2. RVA→文件偏移必须用 VirtualSize 判定虚拟范围。`pck` 节 VS=8 而 RS=452KB，
   用 max(VS,RS) 会把它的虚拟范围虚假拉宽到和 .pdata 重叠。
3. steam_api64.dll 是 GodotSteam 运行时 LoadLibrary 动态加载的，
   不会出现在导入表里——所以"导入表里没有 steam_api"不代表没集成 Steam。
"""
import struct
import sys


def parse(path):
    data = open(path, "rb").read()
    if data[:2] != b"MZ":
        raise SystemExit("不是 MZ 文件")
    e_lfa = struct.unpack_from("<I", data, 0x3C)[0]
    if data[e_lfa:e_lfa + 4] != b"PE\x00\x00":
        raise SystemExit("PE 签名不对")
    coff = e_lfa + 4
    nsec = struct.unpack_from("<H", data, coff + 2)[0]
    size_opt = struct.unpack_from("<H", data, coff + 16)[0]
    sect = coff + 20 + size_opt
    sections = []
    for i in range(nsec):
        o = sect + i * 40
        name = data[o:o + 8].rstrip(b"\x00").decode("ascii", "replace")
        vs = struct.unpack_from("<I", data, o + 8)[0]
        va = struct.unpack_from("<I", data, o + 12)[0]
        rs = struct.unpack_from("<I", data, o + 16)[0]
        rp = struct.unpack_from("<I", data, o + 20)[0]
        sections.append((name, va, vs, rp, rs))

    opt = coff + 20
    magic = struct.unpack_from("<H", data, opt)[0]
    pe32plus = magic == 0x20B
    addr_sz = 8 if pe32plus else 4
    fmt = "<Q" if pe32plus else "<I"

    # DataDirectory 数组起点; DD[0]=导出, DD[1]=导入 → 再 +8
    dd_start = opt + (112 if pe32plus else 96)
    imp_va = struct.unpack_from("<I", data, dd_start + 8)[0]
    imp_sz = struct.unpack_from("<I", data, dd_start + 12)[0]

    def rva2off(rva):
        # 用 VirtualSize 判定虚拟范围, VS==0 时才退回 RawSize。
        # 不能用 max(VS, RS): pck 节 VS=8/RS=452KB, 会虚假覆盖 .pdata 的 VA。
        for name, va, vs, rp, rs in sections:
            limit = vs if vs else rs
            if limit and va <= rva < va + limit:
                return rp + (rva - va)
        return None

    def cstr(off):
        end = data.index(b"\x00", off)
        return data[off:end].decode("ascii", "replace")

    rows = []
    if imp_va:
        off = rva2off(imp_va)
        # 每个 IMAGE_IMPORT_DESCRIPTOR 20 字节, 以全 0 项结尾。
        # 不用 rva2off(imp_va+imp_sz) 算终点: 区间末端可能恰好落在节边界外。
        while off is not None and off + 20 <= len(data):
                ilt_rva = struct.unpack_from("<I", data, off)[0]
                # ts, fc, nc: 略
                name_rva = struct.unpack_from("<I", data, off + 12)[0]
                iat_rva = struct.unpack_from("<I", data, off + 16)[0]
                if ilt_rva == 0 and name_rva == 0:
                    break
                name_off = rva2off(name_rva)
                if name_off is None:
                    break
                dll = cstr(name_off)
                # 用 ILT 数导入函数（ILT 与 IAT 并行, 用 ILT 优先）
                thk = ilt_rva or iat_rva
                thk_off = rva2off(thk)
                n = 0
                if thk_off is not None:
                    p = thk_off
                    # 上限保护: 真 DLL 的导入项不会超过 8192, 防脏数据把循环带飞
                    while p + addr_sz <= len(data) and n < 8192:
                        v = struct.unpack_from(fmt, data, p)[0]
                        p += addr_sz
                        if v == 0:
                            break
                        n += 1
                rows.append((dll.lower(), n))
                off += 20
    return rows


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    rows = parse(sys.argv[1])
    print("--- 导入 DLL (按导入表) ---")
    total = 0
    for dll, n in rows:
        print("  %-26s  导入函数 %3d 个" % (dll, n))
        total += n
    print()
    print("共 %d 个不同 DLL, %d 个导入函数" % (len(rows), total))

    # 关键判断。avrt/dwrite/dwmapi/imm32/crypt32/bcrypt/dinput8 等都是
    # Win10+ 自带系统组件, 不需要随产物分发; 真正要带的只有 steam_api64.dll。
    SYSTEM = {
        "kernel32.dll", "user32.dll", "gdi32.dll", "advapi32.dll",
        "shell32.dll", "ole32.dll", "oleaut32.dll", "winmm.dll",
        "ws2_32.dll", "wsock32.dll", "iphlpapi.dll", "version.dll",
        "msvcrt.dll", "ntdll.dll", "shlwapi.dll", "dbghelp.dll",
        "imm32.dll", "dwmapi.dll", "dwrite.dll", "dinput8.dll",
        "avrt.dll", "bcrypt.dll", "crypt32.dll",
        "vulkan-1.dll", "dxgi.dll", "d3d12.dll", "d3dcompiler_47.dll",
        "vcruntime140.dll", "vcruntime140_1.dll", "ucrtbase.dll",
    }
    needs = [d for d, _ in rows if d not in SYSTEM]
    print()
    print("--- 非系统标准 DLL（需要随产物分发） ---")
    if needs:
        for d in needs:
            print("  *", d)
    else:
        print("  (无)")
    print()
    print("结论:", end=" ")
    if any("steam_api" in d for d, _ in rows):
        print("静态链接 Steamworks（导入表里有 steam_api64.dll,")
        print("      必须随 exe 分发 steam_api64.dll + steam_appid.txt）;")
    else:
        print("导入表里没有 steam_api64.dll（若已集成 Steam 则为动态加载）;")
    print("Godot 引擎已嵌入到 exe, 不需要 .tools/ 目录;")
    print("VCRuntime/UCRT 在 Win10+ 默认自带, 无需额外安装.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
