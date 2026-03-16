#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
import time
from typing import Iterable


ROOTS = (
    "/Users/pfeodrippe/dev/zig-ghostty-hot-0.15.2/",
    "/Users/pfeodrippe/dev/ghostty-hot-0.15.2/",
)


def is_hot_command(cmd: str) -> bool:
    argv0 = cmd.split(None, 1)[0] if cmd.strip() else ""
    return os.path.basename(argv0) in {"zig", "build"}


def root_matches(cmd: str, root: str) -> bool:
    if root.endswith("/"):
        return root in cmd
    start = 0
    while True:
        index = cmd.find(root, start)
        if index == -1:
            return False
        end = index + len(root)
        if end == len(cmd) or cmd[end] in {"/", " ", "\t"}:
            return True
        start = index + 1


def matching_rows_from_ps_output(
    out: str,
    roots: Iterable[str] = ROOTS,
) -> list[tuple[int, int, str, str]]:
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
        if not is_hot_command(cmd):
            continue
        if not any(root_matches(cmd, root) for root in roots):
            continue
        rows.append((pid, ppid, stat, cmd))
    return rows


def matching_rows(roots: Iterable[str] = ROOTS) -> list[tuple[int, int, str, str]]:
    out = subprocess.check_output(
        ["ps", "-Ao", "pid=,ppid=,stat=,command="],
        text=True,
    )
    return matching_rows_from_ps_output(out, roots)


def format_cmd(cmd: str, limit: int = 160) -> str:
    if len(cmd) <= limit:
        return cmd
    return cmd[: limit - 3] + "..."


def main() -> int:
    roots = tuple(arg for arg in sys.argv[1:] if arg) or ROOTS
    rows = matching_rows(roots)
    if not rows:
        return 0

    pids = [str(pid) for pid, _, _, _ in rows]
    print(f"orphaned hot processes: {len(rows)}")
    for pid, ppid, stat, cmd in rows:
        print(f"{pid} ppid={ppid} stat={stat} cmd={format_cmd(cmd)}")

    for sig in (signal.SIGTERM, signal.SIGKILL):
        subprocess.run(["kill", f"-{sig.value}", *pids], check=False)
        time.sleep(1)
        rows = matching_rows(roots)
        if not rows:
            print("cleanup complete")
            return 0
        pids = [str(pid) for pid, _, _, _ in rows]

    print(f"remaining orphaned hot processes: {len(rows)}")
    for pid, ppid, stat, cmd in rows:
        print(f"{pid} ppid={ppid} stat={stat} cmd={format_cmd(cmd)}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
