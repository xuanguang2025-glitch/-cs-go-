"""
smoke_test.py — 发布版 exe 冒烟测试。

背景：
  release 导出不带 console wrapper（debug/export_console_wrapper 只作用于
  debug 导出），所以双击 exe 是看不到任何日志的。这里用 Python 起进程并
  显式接管 stdout/stderr 的文件句柄，把 Godot 的 print 输出落盘。

  不能用 shell 的 `> file 2>&1`：在这个宿主里后台任务的重定向不可靠，
  日志文件经常根本不会被创建。

用法：
  python smoke_test.py [--mode headless|windowed] [--seconds 20] [--kill]
"""

import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
EXE = os.path.join(HERE, "build", "PROJECT_STRIKE.exe")
LOGDIR = os.path.join(HERE, "build")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="headless",
                    choices=["headless", "windowed"])
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--kill", action="store_true",
                    help="测试结束后结束进程（默认是留给玩家继续运行）")
    args = ap.parse_args()

    if not os.path.exists(EXE):
        print("找不到 exe:", EXE)
        return 1

    cmd = [EXE]
    if args.mode == "headless":
        cmd.append("--headless")
    # 有窗口时给个固定分辨率，避免全屏挡住桌面
    else:
        cmd += ["--resolution", "1280x720"]

    out_path = os.path.join(LOGDIR, "smoke_out.log")
    err_path = os.path.join(LOGDIR, "smoke_err.log")

    print("启动: %s" % " ".join(cmd))
    print("模式: %s / 观察 %.0f 秒 / 结束后 %s"
          % (args.mode, args.seconds, "结束进程" if args.kill else "保留进程"))

    fo = open(out_path, "wb")
    fe = open(err_path, "wb")
    p = subprocess.Popen(cmd, cwd=os.path.join(HERE, "build"),
                         stdout=fo, stderr=fe)
    print("PID = %d" % p.pid)

    deadline = time.time() + args.seconds
    alive = True
    while time.time() < deadline:
        rc = p.poll()
        if rc is not None:
            alive = False
            print("进程自行退出，退出码 = %s" % rc)
            break
        time.sleep(0.5)

    if alive:
        print("观察期结束，进程仍在运行（未崩溃）")
        if args.kill:
            p.terminate()
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.kill()
            print("已结束进程")

    fo.close()
    fe.close()

    for name, path in (("stdout", out_path), ("stderr", err_path)):
        print("\n===== %s (%d bytes) ====="
              % (name, os.path.getsize(path) if os.path.exists(path) else 0))
        if not os.path.exists(path) or os.path.getsize(path) == 0:
            print("(空)")
            continue
        raw = open(path, "rb").read()
        text = None
        for enc in ("utf-16-le", "utf-8", "gbk"):
            try:
                t = raw.decode(enc)
                if t.count("\x00") > len(t) // 4:
                    continue
                text = t
                break
            except UnicodeDecodeError:
                continue
        if text is None:
            text = raw.decode("utf-8", errors="replace")
        lines = [l for l in text.splitlines() if l.strip()]
        for l in lines[:60]:
            print("  " + l)
        if len(lines) > 60:
            print("  ... 还有 %d 行" % (len(lines) - 60))

    return 0


if __name__ == "__main__":
    sys.exit(main())
