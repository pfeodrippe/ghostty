#!/usr/bin/env python3
import os
import shlex
import subprocess
import sys
from typing import Iterable


def recovery_dir(path: str, index: int) -> str:
    return f"{path}-recover-{index}"


def parse_lsof_pids(output: str) -> set[int]:
    pids: set[int] = set()
    for line in output.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            pids.add(int(parts[1]))
        except ValueError:
            continue
    return pids


def cache_holders(paths: Iterable[str]) -> set[int]:
    pids: set[int] = set()
    for path in paths:
        if not os.path.exists(path):
            continue
        proc = subprocess.run(
            ["lsof", "+D", path],
            check=False,
            capture_output=True,
            text=True,
        )
        if proc.stdout:
            pids.update(parse_lsof_pids(proc.stdout))
    return pids


def choose_cache_dirs(
    cache_dir: str,
    global_cache_dir: str,
    holder_lookup,
) -> tuple[str, str]:
    if not holder_lookup((cache_dir, global_cache_dir)):
        return cache_dir, global_cache_dir

    index = 1
    while True:
        candidate_cache = recovery_dir(cache_dir, index)
        candidate_global = recovery_dir(global_cache_dir, index)
        if not holder_lookup((candidate_cache, candidate_global)):
            return candidate_cache, candidate_global
        index += 1


def emit_shell(cache_dir: str, global_cache_dir: str) -> None:
    print(f"HOT_CACHE_DIR={shlex.quote(cache_dir)}")
    print(f"HOT_GLOBAL_CACHE_DIR={shlex.quote(global_cache_dir)}")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: resolve_hot_cache_dirs.py <cache-dir> <global-cache-dir>",
            file=sys.stderr,
        )
        return 2

    cache_dir = argv[1]
    global_cache_dir = argv[2]

    chosen_cache, chosen_global = choose_cache_dirs(
        cache_dir,
        global_cache_dir,
        cache_holders,
    )
    if (chosen_cache, chosen_global) != (cache_dir, global_cache_dir):
        blockers = sorted(cache_holders((cache_dir, global_cache_dir)))
        print(
            "hot cache dirs are still held by "
            f"{', '.join(str(pid) for pid in blockers)}; "
            f"using recovery caches {chosen_cache} and {chosen_global}",
            file=sys.stderr,
        )

    emit_shell(chosen_cache, chosen_global)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
