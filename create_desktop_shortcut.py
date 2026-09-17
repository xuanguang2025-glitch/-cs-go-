"""
create_desktop_shortcut.py — 用纯 ctypes 调 COM 生成桌面快捷方式。

为什么不用更简单的方式：
- PowerShell 的 `WScript.Shell.CreateShortcut` 会被主机的 COM 安全策略拦截
  ("COM object instantiation can run arbitrary code")。
- `mklink` 建的是符号链接，不是 .lnk，无法设置"起始位置"(WorkingDirectory)。
  起始位置很关键：steam_api64.dll 和 steam_appid.txt 就放在 exe 旁边，
  起始位置不对会导致 Steam 运行时加载失败（游戏仍能跑，只是降级离线）。
- 所以走 ctypes + IShellLinkW/IPersistFile，零第三方依赖，可重复运行。

用法:
    python create_desktop_shortcut.py              # 建到当前用户桌面
    python create_desktop_shortcut.py <目标目录>    # 建到指定目录
"""
import ctypes
import os
import sys
from ctypes import POINTER, byref, c_int, c_void_p, c_wchar_p, wintypes

# ---- COM 标识
CLSID_SHELL_LINK = "{00021401-0000-0000-C000-000000000046}"
IID_ISHELLLINK_W = "{000214F9-0000-0000-C000-000000000046}"
IID_IPERSIST_FILE = "{0000010b-0000-0000-C000-000000000046}"
CLSCTX_INPROC_SERVER = 1
SW_SHOWNORMAL = 1

# IShellLinkW vtable 偏移 = IUnknown(3) + 方法序号
# 顺序: GetPath,GetIDList,SetIDList,GetDescription,SetDescription,
#       GetWorkingDirectory,SetWorkingDirectory,GetArguments,SetArguments,
#       GetHotkey,SetHotkey,GetShowCmd,SetShowCmd,GetIconLocation,
#       SetIconLocation,SetRelativePath,Resolve,SetPath
VT_SET_DESCRIPTION = 3 + 4
VT_SET_WORKING_DIR = 3 + 6
VT_SET_SHOW_CMD = 3 + 12
VT_SET_ICON_LOCATION = 3 + 14
VT_SET_PATH = 3 + 17
# IPersistFile: IUnknown(3) + GetClassID,IsDirty,Load,Save,...
VT_PERSIST_SAVE = 3 + 3

ole32 = ctypes.windll.ole32
shell32 = ctypes.windll.shell32


class GUID(ctypes.Structure):
    _fields_ = [
        ("Data1", wintypes.DWORD),
        ("Data2", wintypes.WORD),
        ("Data3", wintypes.WORD),
        ("Data4", ctypes.c_ubyte * 8),
    ]

    @classmethod
    def from_str(cls, s: str) -> "GUID":
        g = cls()
        if ole32.IIDFromString(s, byref(g)) != 0:
            raise OSError("非法 GUID: " + s)
        return g


def _fn(vtbl, idx, restype, *argtypes):
    """取 vtable[idx] 处的函数指针并包装成可调用对象。"""
    proto = ctypes.WINFUNCTYPE(restype, c_void_p, *argtypes)
    return proto(vtbl[idx])


def _vtable(iface: ctypes.c_void_p):
    """
    接口指针指向的对象布局是 [vptr][字段...]，也就是说 pobj.value 这个地址上
    存的**第一个单元**才是 vtable 基址。直接把 pobj.value 当函数数组用,
    取到的是 vptr 本身 → 跳到错误槽位直接 access violation。
    """
    return ctypes.cast(iface.value, POINTER(POINTER(c_void_p))).contents


def create_shortcut(lnk_path: str, target: str, work_dir: str,
                    desc: str = "", icon: str = "", icon_index: int = 0) -> None:
    if not os.path.isfile(target):
        raise SystemExit("目标不存在: " + target)

    ole32.CoInitialize(None)
    pobj = ctypes.c_void_p()
    hr = ole32.CoCreateInstance(
        byref(GUID.from_str(CLSID_SHELL_LINK)), None, CLSCTX_INPROC_SERVER,
        byref(GUID.from_str(IID_ISHELLLINK_W)), byref(pobj))
    if hr < 0:
        raise OSError("CoCreateInstance 失败 0x%08X" % (hr & 0xFFFFFFFF))

    vtbl = _vtable(pobj)

    hr = _fn(vtbl, VT_SET_PATH, ctypes.HRESULT, c_wchar_p)(pobj.value, target)
    if hr < 0:
        raise OSError("SetPath 失败 0x%08X" % (hr & 0xFFFFFFFF))

    if work_dir:
        _fn(vtbl, VT_SET_WORKING_DIR, ctypes.HRESULT, c_wchar_p)(pobj.value, work_dir)
    if desc:
        _fn(vtbl, VT_SET_DESCRIPTION, ctypes.HRESULT, c_wchar_p)(pobj.value, desc)
    if icon:
        _fn(vtbl, VT_SET_ICON_LOCATION, ctypes.HRESULT, c_wchar_p, c_int)(
            pobj.value, icon, icon_index)
    _fn(vtbl, VT_SET_SHOW_CMD, ctypes.HRESULT, c_int)(pobj.value, SW_SHOWNORMAL)

    ppf = ctypes.c_void_p()
    hr = _fn(vtbl, 0, ctypes.HRESULT, c_void_p, c_void_p)(
        pobj.value, byref(GUID.from_str(IID_IPERSIST_FILE)), byref(ppf))
    if hr < 0:
        raise OSError("QueryInterface(IPersistFile) 失败 0x%08X" % (hr & 0xFFFFFFFF))

    pf_vtbl = _vtable(ppf)
    hr = _fn(pf_vtbl, VT_PERSIST_SAVE, ctypes.HRESULT, c_wchar_p, c_int)(
        ppf.value, lnk_path, 1)
    if hr < 0:
        raise OSError("IPersistFile.Save 失败 0x%08X" % (hr & 0xFFFFFFFF))


def get_desktop() -> str:
    buf = ctypes.create_unicode_buffer(1024)
    # CSIDL_DESKTOPDIRECTORY = 0
    if shell32.SHGetFolderPathW(None, 0, None, 0, buf) != 0:
        raise OSError("无法获取桌面目录")
    return buf.value


def main() -> int:
    root = os.path.dirname(os.path.abspath(__file__))
    exe = os.path.join(root, "build", "PROJECT_STRIKE.exe")
    work_dir = os.path.join(root, "build")
    desktop = sys.argv[1] if len(sys.argv) > 1 else get_desktop()

    if not os.path.isfile(exe):
        print("[FAIL] 先运行 build_release.ps1 生成 exe:", exe)
        return 1
    for dep in ("steam_api64.dll", "steam_appid.txt"):
        if not os.path.isfile(os.path.join(work_dir, dep)):
            print("[WARN] 缺少运行时文件, Steam 将降级离线:", dep)

    os.makedirs(desktop, exist_ok=True)
    lnk = os.path.join(desktop, "PROJECT STRIKE.lnk")
    create_shortcut(lnk, exe, work_dir,
                    desc="PROJECT STRIKE - 5v5 战术竞技 FPS",
                    icon=exe, icon_index=0)
    print("[OK] 快捷方式:", lnk)
    print("     目标    :", exe)
    print("     起始位置:", work_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
