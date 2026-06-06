#!/usr/bin/env python3
"""Drive the event-loop example (examples/async.zig) through a real PTY.

    zig build && python3 tools/pty_async.py

Marker-driven (waits for expected output rather than sleeping), so it is not
timing-sensitive. Exits non-zero if any check fails.
"""
import os
import pty
import select
import sys
import time

BIN = "./zig-out/bin/stanza-async"


def main() -> int:
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(BIN, ["stanza-async"])
        os._exit(127)

    buf = b""

    def drain(seconds: float) -> None:
        nonlocal buf
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                continue
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            buf += data
            if b"\x1b[6n" in data:  # answer the cursor-position report
                os.write(fd, b"\x1b[1;80R")

    def wait_for(substr: str, timeout: float = 4.0) -> bool:
        end = time.time() + timeout
        needle = substr.encode()
        while needle not in buf and time.time() < end:
            drain(0.1)
        return needle in buf

    def wait_exit(timeout: float = 4.0):
        nonlocal buf
        end = time.time() + timeout
        draining = True
        while time.time() < end:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done != 0:
                return status
            if not draining:  # PTY is dead; just keep polling for the exit
                time.sleep(0.05)
                continue
            # keep draining so the child never blocks writing to a full PTY
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                continue
            try:
                data = os.read(fd, 4096)
            except OSError:  # Linux raises EIO once the child side closes...
                draining = False
                continue
            if not data:  # ...macOS reports EOF instead
                draining = False
                continue
            buf += data
            if b"\x1b[6n" in data:
                os.write(fd, b"\x1b[1;80R")
        return None

    prompt_drawn = wait_for("async")  # the "async ❯ " prompt
    os.write(fd, b"hello\r")          # type and submit through the event loop
    processed = wait_for("ran after") # main printed the result
    # Stay idle past the 1s tick: the example hides the prompt, prints the
    # tick line, and shows the prompt again — verify that ordering.
    ticked = wait_for("tick: idle 1", timeout=4.0)
    prompt_bytes = "async ❯".encode()
    repainted = False
    if ticked:
        after_tick = buf.index(b"tick: idle 1")
        end = time.time() + 4.0
        while not repainted and time.time() < end:
            repainted = buf.find(prompt_bytes, after_tick) != -1
            if not repainted:
                drain(0.1)
    os.write(fd, b"\x04")             # Ctrl-D on the fresh empty line -> quit
    status = wait_exit()
    try:
        os.close(fd)
    except OSError:
        pass

    checks = {
        "prompt drawn": prompt_drawn,
        "line submitted via event loop": processed and "hello" in buf.decode("utf-8", "replace"),
        "tick printed via hide/show": ticked,
        "prompt repainted after tick": repainted,
        "exited cleanly on Ctrl-D": status is not None
        and os.WIFEXITED(status)
        and os.WEXITSTATUS(status) == 0,
    }
    ok = True
    for name, passed in checks.items():
        print(f"[{'ok' if passed else 'FAIL'}] {name}")
        ok = ok and passed
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
