#!/usr/bin/env python3
"""Drive stanza-demo through Windows ConPTY.

    zig build && python tools/conpty_smoke.py

The script exercises the raw Windows console path, not the plain pipe fallback:
completion, submit, reverse search, vi editing, and clean exit.
"""

import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import sys
import time


BIN = Path("zig-out/bin/stanza-demo.exe")
HIST = Path(".stanza_demo_history")
WAIT_OBJECT_0 = 0

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True) if os.name == "nt" else None


class COORD(ctypes.Structure):
    _fields_ = [("X", ctypes.c_short), ("Y", ctypes.c_short)]


class STARTUPINFOW(ctypes.Structure):
    _fields_ = [
        ("cb", wintypes.DWORD),
        ("lpReserved", wintypes.LPWSTR),
        ("lpDesktop", wintypes.LPWSTR),
        ("lpTitle", wintypes.LPWSTR),
        ("dwX", wintypes.DWORD),
        ("dwY", wintypes.DWORD),
        ("dwXSize", wintypes.DWORD),
        ("dwYSize", wintypes.DWORD),
        ("dwXCountChars", wintypes.DWORD),
        ("dwYCountChars", wintypes.DWORD),
        ("dwFillAttribute", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("wShowWindow", wintypes.WORD),
        ("cbReserved2", wintypes.WORD),
        ("lpReserved2", ctypes.c_void_p),
        ("hStdInput", wintypes.HANDLE),
        ("hStdOutput", wintypes.HANDLE),
        ("hStdError", wintypes.HANDLE),
    ]


class STARTUPINFOEXW(ctypes.Structure):
    _fields_ = [
        ("StartupInfo", STARTUPINFOW),
        ("lpAttributeList", ctypes.c_void_p),
    ]


class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("hProcess", wintypes.HANDLE),
        ("hThread", wintypes.HANDLE),
        ("dwProcessId", wintypes.DWORD),
        ("dwThreadId", wintypes.DWORD),
    ]


def setup_api() -> None:
    kernel32.CreatePipe.argtypes = [
        ctypes.POINTER(wintypes.HANDLE),
        ctypes.POINTER(wintypes.HANDLE),
        ctypes.c_void_p,
        wintypes.DWORD,
    ]
    kernel32.CreatePipe.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    kernel32.CreatePseudoConsole.argtypes = [
        COORD,
        wintypes.HANDLE,
        wintypes.HANDLE,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.HANDLE),
    ]
    kernel32.CreatePseudoConsole.restype = ctypes.c_long
    kernel32.ClosePseudoConsole.argtypes = [wintypes.HANDLE]
    kernel32.InitializeProcThreadAttributeList.argtypes = [
        ctypes.c_void_p,
        wintypes.DWORD,
        wintypes.DWORD,
        ctypes.POINTER(ctypes.c_size_t),
    ]
    kernel32.InitializeProcThreadAttributeList.restype = wintypes.BOOL
    kernel32.UpdateProcThreadAttribute.argtypes = [
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.c_size_t,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t),
    ]
    kernel32.UpdateProcThreadAttribute.restype = wintypes.BOOL
    kernel32.DeleteProcThreadAttributeList.argtypes = [ctypes.c_void_p]
    kernel32.CreateProcessW.argtypes = [
        wintypes.LPCWSTR,
        wintypes.LPWSTR,
        ctypes.c_void_p,
        ctypes.c_void_p,
        wintypes.BOOL,
        wintypes.DWORD,
        ctypes.c_void_p,
        wintypes.LPCWSTR,
        ctypes.POINTER(STARTUPINFOEXW),
        ctypes.POINTER(PROCESS_INFORMATION),
    ]
    kernel32.CreateProcessW.restype = wintypes.BOOL
    kernel32.PeekNamedPipe.argtypes = [
        wintypes.HANDLE,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
        ctypes.POINTER(wintypes.DWORD),
        ctypes.POINTER(wintypes.DWORD),
    ]
    kernel32.PeekNamedPipe.restype = wintypes.BOOL
    kernel32.ReadFile.argtypes = [
        wintypes.HANDLE,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
        ctypes.c_void_p,
    ]
    kernel32.ReadFile.restype = wintypes.BOOL
    kernel32.WriteFile.argtypes = [
        wintypes.HANDLE,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
        ctypes.c_void_p,
    ]
    kernel32.WriteFile.restype = wintypes.BOOL
    kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel32.WaitForSingleObject.restype = wintypes.DWORD
    kernel32.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    kernel32.TerminateProcess.restype = wintypes.BOOL


def last_error() -> OSError:
    return ctypes.WinError(ctypes.get_last_error())


def check(ok: bool, what: str) -> None:
    if not ok:
        raise RuntimeError(f"{what}: {last_error()}")


def close(handle: wintypes.HANDLE) -> None:
    if handle:
        kernel32.CloseHandle(handle)


class Conpty:
    def __init__(self, exe: Path):
        self.exe = exe
        self.in_write = wintypes.HANDLE()
        self.out_read = wintypes.HANDLE()
        self.hpc = wintypes.HANDLE()
        self.pi = PROCESS_INFORMATION()
        self.attr_buf = None
        self.buf = bytearray()

    def start(self) -> None:
        in_read = wintypes.HANDLE()
        out_write = wintypes.HANDLE()
        check(kernel32.CreatePipe(ctypes.byref(in_read), ctypes.byref(self.in_write), None, 0), "CreatePipe(input)")
        check(kernel32.CreatePipe(ctypes.byref(self.out_read), ctypes.byref(out_write), None, 0), "CreatePipe(output)")
        try:
            hr = kernel32.CreatePseudoConsole(COORD(100, 30), in_read, out_write, 0, ctypes.byref(self.hpc))
            if hr != 0:
                raise RuntimeError(f"CreatePseudoConsole failed: HRESULT 0x{hr & 0xffffffff:08x}")
        finally:
            close(in_read)
            close(out_write)

        si = self._startup_info()
        cmd = ctypes.create_unicode_buffer(f'"{self.exe}"')
        flags = 0x00080000  # EXTENDED_STARTUPINFO_PRESENT
        check(
            kernel32.CreateProcessW(
                None,
                cmd,
                None,
                None,
                False,
                flags,
                None,
                None,
                ctypes.byref(si),
                ctypes.byref(self.pi),
            ),
            "CreateProcessW",
        )
        close(self.pi.hThread)

    def _startup_info(self) -> STARTUPINFOEXW:
        size = ctypes.c_size_t()
        kernel32.InitializeProcThreadAttributeList(None, 1, 0, ctypes.byref(size))
        self.attr_buf = ctypes.create_string_buffer(size.value)
        attr_list = ctypes.cast(self.attr_buf, ctypes.c_void_p)
        check(
            kernel32.InitializeProcThreadAttributeList(attr_list, 1, 0, ctypes.byref(size)),
            "InitializeProcThreadAttributeList",
        )
        hpc_value = ctypes.c_void_p(self.hpc.value)
        proc_thread_attribute_pseudoconsole = 0x00020016
        check(
            kernel32.UpdateProcThreadAttribute(
                attr_list,
                0,
                proc_thread_attribute_pseudoconsole,
                hpc_value,
                ctypes.sizeof(wintypes.HANDLE),
                None,
                None,
            ),
            "UpdateProcThreadAttribute",
        )
        si = STARTUPINFOEXW()
        si.StartupInfo.cb = ctypes.sizeof(STARTUPINFOEXW)
        si.lpAttributeList = attr_list
        return si

    def write(self, data: bytes) -> None:
        raw = ctypes.create_string_buffer(data)
        wrote = wintypes.DWORD()
        check(kernel32.WriteFile(self.in_write, raw, len(data), ctypes.byref(wrote), None), "WriteFile")
        if wrote.value != len(data):
            raise RuntimeError(f"short write: {wrote.value} of {len(data)}")

    def drain(self, seconds: float) -> None:
        end = time.time() + seconds
        while time.time() < end:
            avail = wintypes.DWORD()
            check(kernel32.PeekNamedPipe(self.out_read, None, 0, None, ctypes.byref(avail), None), "PeekNamedPipe")
            if avail.value:
                chunk = ctypes.create_string_buffer(avail.value)
                got = wintypes.DWORD()
                check(kernel32.ReadFile(self.out_read, chunk, avail.value, ctypes.byref(got), None), "ReadFile")
                self.buf.extend(chunk.raw[: got.value])
                continue
            time.sleep(0.03)

    def wait_for(self, text: str, timeout: float = 5.0) -> bool:
        needle = text.encode()
        end = time.time() + timeout
        while needle not in self.buf and time.time() < end:
            self.drain(0.1)
        return needle in self.buf

    def send(self, data: bytes, gap: float = 0.25) -> None:
        self.write(data)
        self.drain(gap)

    def stop(self) -> None:
        if self.pi.hProcess:
            if kernel32.WaitForSingleObject(self.pi.hProcess, 0) != WAIT_OBJECT_0:
                kernel32.TerminateProcess(self.pi.hProcess, 1)
            close(self.pi.hProcess)
        close(self.in_write)
        close(self.out_read)
        if self.hpc:
            kernel32.ClosePseudoConsole(self.hpc)
        if self.attr_buf is not None:
            kernel32.DeleteProcThreadAttributeList(ctypes.cast(self.attr_buf, ctypes.c_void_p))


def main() -> int:
    if os.name != "nt":
        print("[skip] ConPTY smoke requires Windows")
        return 0
    setup_api()

    exe = (Path(sys.argv[1]) if len(sys.argv) > 1 else BIN).resolve()
    if not exe.exists():
        print(f"[FAIL] demo binary not found: {exe}")
        return 1
    if HIST.exists():
        HIST.unlink()

    cp = Conpty(exe)
    ok = True
    try:
        cp.start()
        cp.wait_for("git")
        cp.send(b"com\t")
        cp.send(b"\r")
        cp.send(b"\x12")
        cp.send(b"com")
        cp.send(b"\r")
        cp.send(b"orld")
        cp.send(b"\x1b")
        cp.send(b"Iw")
        cp.send(b"\x1b")
        cp.send(b"\r")
        cp.send(b"foo bar")
        cp.send(b"\x1b")
        cp.send(b"0dw")
        cp.send(b"\r")
        cp.send(b"quit\r")
        cp.wait_for("bye.")
        if kernel32.WaitForSingleObject(cp.pi.hProcess, 5000) != WAIT_OBJECT_0:
            raise RuntimeError("demo did not exit after quit")

        text = bytes(cp.buf).decode("utf-8", "replace")
        checks = {
            "completion renders commit": "commit" in text,
            "typed commit submitted": "ran: git commit" in text,
            "reverse search prompt shown": "reverse-i-search" in text,
            "commit recalled via Ctrl-R": text.count("ran: git commit") >= 2,
            "vi I inserts at start": "ran: git world" in text,
            "vi dw deletes word": "ran: git bar" in text,
            "clean exit": "bye." in text,
        }
        for name, passed in checks.items():
            print(f"[{'ok' if passed else 'FAIL'}] {name}")
            ok = ok and passed
    finally:
        cp.stop()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
