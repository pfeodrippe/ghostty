#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
import time


ROOTS = (
    "/Users/pfeodrippe/dev/zig-ghostty-hot-0.15.2/",
    "/Users/pfeodrippe/dev/ghostty-hot-0.15.2/",
)


def is_zig_command(cmd: str) -> bool:
    argv0 = cmd.split(None, 1)[0] if cmd.strip() else ""
    return os.path.basename(argv0) == "zig"


def matching_rows() -> list[tuple[int, int, str, str]]:
    out = subprocess.check_output(
        ["ps", "-Ao", "pid=,ppid=,stat=,command="],
        text=True,
    )
    rows: list[tuple[int, int, str, str]] = []
    for line in out.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) != 4:
            continue
        pid_s, ppid_s, stat, cmd = parts
        try:
            pid = int(pid_s)
            ppid = int(ppid_s)
        except ValueError:
            continue
        if ppid != 1:
            continue
        if not is_zig_command(cmd):
            continue
        if not any(root in cmd for root in ROOTS):
            continue
        rows.append((pid, ppid, stat, cmd))
    return rows


def main() -> int:
    rows = matching_rows()
    if not rows:
        print("no orphaned hot zig processes found")
        return 0

    pids = [str(pid) for pid, _, _, _ in rows]
    print("orphaned hot zig processes:")
    for pid, ppid, stat, cmd in rows:
        print(f"{pid} ppid={ppid} stat={stat} cmd={cmd}")

    for sig in (signal.SIGTERM, signal.SIGKILL):
        subprocess.run(["kill", f"-{sig.value}", *pids], check=False)
        time.sleep(1)
        rows = matching_rows()
        if not rows:
            print("cleanup complete")
            return 0
        pids = [str(pid) for pid, _, _, _ in rows]

    print("remaining orphaned hot zig processes:")
    for pid, ppid, stat, cmd in rows:
        print(f"{pid} ppid={ppid} stat={stat} cmd={cmd}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
