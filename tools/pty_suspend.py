#!/usr/bin/env python3
"""Suspend/resume through a PTY: Ctrl-Z must restore the terminal and stop
the process; SIGCONT must re-enter raw mode and repaint the line being edited.

    zig build && python3 tools/pty_suspend.py

Uses a manual fork without setsid so the child stays in this process group —
`pty.fork` would make it a session leader in an orphaned process group, and
POSIX discards stop signals for those, which would mask a real failure.
"""
import os
import select
import signal
import sys
import time

BIN = "./zig-out/bin/stanza-demo"
HIST = ".stanza_demo_history"


def main() -> int:
    if os.name == "nt":
        print("[skip] suspend/resume requires POSIX job control")
        return 0
    if os.path.exists(HIST):
        os.remove(HIST)

    master, slave = os.openpty()
    pid = os.fork()
    if pid == 0:
        # Own process group, same session: its parent (us) is outside the
        # group, so the group is not orphaned and SIGTSTP actually stops it.
        os.setpgid(0, 0)
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(master)
        os.close(slave)
        os.execv(BIN, ["stanza-demo"])
        os._exit(127)
    try:
        os.setpgid(pid, pid)  # mirror the child's setpgid; loser of the race is fine
    except OSError:
        pass
    os.close(slave)

    buf = b""

    def drain(seconds: float) -> None:
        nonlocal buf
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([master], [], [], 0.05)
            if not r:
                continue
            try:
                data = os.read(master, 4096)
            except OSError:
                break
            if not data:
                break
            buf += data
            if b"\x1b[6n" in data:  # answer the cursor-position query
                os.write(master, b"\x1b[1;80R")

    def wait_for(substr: str, timeout: float = 5.0) -> bool:
        end = time.time() + timeout
        needle = substr.encode()
        while needle not in buf and time.time() < end:
            drain(0.1)
        return needle in buf

    prompt_drawn = wait_for("git")  # the "git ❯ " prompt
    os.write(master, b"par")        # leave a partial line on screen
    drain(0.3)

    restore_mark = len(buf)
    os.write(master, b"\x1a")       # Ctrl-Z
    stopped = False
    end = time.time() + 5.0
    while time.time() < end:
        done, status = os.waitpid(pid, os.WUNTRACED | os.WNOHANG)
        if done != 0 and os.WIFSTOPPED(status):
            stopped = True
            break
        drain(0.05)
    drain(0.2)
    # The editor must hand the terminal back before stopping.
    restored = b"\x1b[?2004l" in buf[restore_mark:]

    repaint_mark = len(buf)
    os.kill(pid, signal.SIGCONT)
    resumed = False
    needle = "git ❯".encode()
    end = time.time() + 5.0
    while time.time() < end:
        drain(0.1)
        if buf.find(needle, repaint_mark) != -1:
            resumed = True
            break

    os.write(master, b"tial\r")     # the suspended line must still be there
    submitted = wait_for("ran: git partial")
    os.write(master, b"quit\r")
    wait_for("bye.")
    try:
        os.close(master)
    except OSError:
        pass
    os.waitpid(pid, 0)

    checks = {
        "prompt drawn": prompt_drawn,
        "terminal restored before stopping": restored,
        "process stopped on Ctrl-Z": stopped,
        "prompt repainted after SIGCONT": resumed,
        "suspended line survived (partial)": submitted,
    }
    ok = True
    for name, passed in checks.items():
        print(f"[{'ok' if passed else 'FAIL'}] {name}")
        ok = ok and passed
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
