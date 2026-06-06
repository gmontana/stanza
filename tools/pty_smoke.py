#!/usr/bin/env python3
"""Drive the built demo through a real pseudo-terminal to exercise the
raw-mode editing path that a pipe cannot reach: completion, submit, reverse
search, history recall, vi-mode editing, and clean exit.

    zig build && python3 tools/pty_smoke.py

Marker-anchored (waits for the prompt before typing and for "bye." before
asserting) and drains continuously, so it is not timing-sensitive. The harness
answers the cursor-position (DSR) query so width detection runs. Exits non-zero
if any check fails.
"""
import os
import pty
import select
import sys
import time

BIN = "./zig-out/bin/stanza-demo"
HIST = ".stanza_demo_history"


def main() -> int:
    if os.path.exists(HIST):
        os.remove(HIST)  # deterministic history for the Ctrl-R check

    pid, fd = pty.fork()
    if pid == 0:
        os.execv(BIN, ["stanza-demo"])
        os._exit(127)

    buf = b""

    def drain(seconds: float) -> None:
        nonlocal buf
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if not r:
                continue
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            buf += data
            if b"\x1b[6n" in data:
                os.write(fd, b"\x1b[1;80R")

    def wait_for(substr: str, timeout: float = 5.0) -> bool:
        nonlocal buf
        end = time.time() + timeout
        needle = substr.encode()
        while needle not in buf and time.time() < end:
            drain(0.1)
        return needle in buf

    def send(data: bytes, gap: float = 0.25) -> None:
        # gap (> the 30ms Esc timeout) lets a lone Esc resolve before the next byte
        os.write(fd, data)
        drain(gap)

    wait_for("git")  # the "git ❯ " prompt is up
    send(b"com\t")   # complete -> commit
    send(b"\r")      # submit
    send(b"\x12")    # Ctrl-R reverse search
    send(b"com")     # search term
    send(b"\r")      # accept + submit recalled line
    send(b"orld")    # vi: type
    send(b"\x1b")    # Esc -> normal
    send(b"Iw")      # insert at home, 'w' -> world
    send(b"\x1b")
    send(b"\r")      # submit "world"
    send(b"foo bar")
    send(b"\x1b")
    send(b"0dw")     # home, delete word -> "bar"
    send(b"\r")
    send(b"quit\r")
    wait_for("bye.")
    try:
        os.close(fd)
    except OSError:
        pass
    os.waitpid(pid, 0)

    txt = buf.decode("utf-8", "replace")
    checks = {
        "completion renders 'commit'": "commit" in txt,
        "typed commit submitted": "ran: git commit" in txt,
        "reverse-i-search prompt shown": "reverse-i-search" in txt,
        "commit recalled via Ctrl-R": txt.count("ran: git commit") >= 2,
        "vi I (insert at start) -> world": "ran: git world" in txt,
        "vi dw (delete word) -> bar": "ran: git bar" in txt,
        "clean exit": "bye." in txt,
    }
    ok = True
    for name, passed in checks.items():
        print(f"[{'ok' if passed else 'FAIL'}] {name}")
        ok = ok and passed
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
