"""
recycle_templates.py — 把 build/templates/ 整目录送进回收站

为什么要这样删而不是直接 rm：
  用户偏好「先扫描确认, 再通过回收站等可恢复方式删除」,
  4.78GB 数据直接删太危险。

实现踩过的坑（都试过才写的最终方案）：
  1. ctypes + SHFileOperationW(FO_DELETE | FOF_ALLOWUNDO) —— 整目录调用时
     在这个环境返回 124 (0x7C, 与小目录的 0/2 不同, 不是权限也不是容量问题,
     推断是 SHFileOperation 在递归处理大批量大文件时的返回码差异)。
  2. send2trash.send2trash(整个目录路径) —— 同样在 PermissionError [WinError 5]。
  3. send2trash.send2trash(逐个顶层条目) —— **成功**, 所以这是当前方案。

执行后会自动验证：
  1. 原目录已不存在
  2. 构建真正依赖的 .tools/、APPDATA 模板、rcedit 都还在
"""

import os
import sys
import send2trash

TARGET = r"D:\徐浩然\2026-08-29-21-56-21\PROJECT_STRIKE\build\templates"


def main():
    if not os.path.exists(TARGET):
        print(f"[跳过] {TARGET} 已不存在")
        return 0

    # 最后一次对账
    items = sorted(os.listdir(TARGET))
    total = 0
    for n in items:
        p = os.path.join(TARGET, n)
        if os.path.isdir(p):
            for r, _, fs in os.walk(p):
                for f in fs:
                    try:
                        total += os.path.getsize(os.path.join(r, f))
                    except OSError:
                        pass
        else:
            try:
                total += os.path.getsize(p)
            except OSError:
                pass
    print(f"目标: {TARGET}")
    print(f"规模: {len(items)} 个顶层条目, {total/1024/1024/1024:.2f} GB")
    print("逐项 send2trash.send2trash() ...")

    failed = []
    for n in items:
        p = os.path.join(TARGET, n)
        try:
            send2trash.send2trash(p)
            print(f"  OK   {n}")
        except OSError as e:
            print(f"  FAIL {n}  -> {e}")
            failed.append(n)

    if failed:
        print(f"\n[ERROR] {len(failed)} 项回收失败: {failed}")
        return 1

    # 删掉空目录
    if os.path.isdir(TARGET):
        try:
            os.rmdir(TARGET)
            print("[OK] 顶层目录已清空")
        except OSError:
            print("[WARN] 顶层目录仍在, 残余条目:",
                  sorted(os.listdir(TARGET))[:10])

    # 验证构建依赖
    checks = [
        (r"D:\徐浩然\2026-08-29-21-56-21\.tools\GodotSteam_Editor.exe", "引擎"),
        (r"D:\徐浩然\2026-08-29-21-56-21\.tools\steam_api64.dll", "Steam DLL"),
        (r"C:\GodotTools\rcedit.exe", "rcedit"),
        (os.path.join(os.environ["APPDATA"],
                     r"Godot\export_templates\4.4.1.stable\windows_release_x86_64.exe"),
         "APPDATA Win 模板"),
    ]
    print("\n--- 构建依赖 ---")
    for p, label in checks:
        ok = os.path.exists(p)
        print(f"  [{'OK' if ok else '缺失'}] {label}")

    return 0


if __name__ == "__main__":
    sys.exit(main())