#!/usr/bin/env python3

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import dataclasses
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ZIG = ROOT / ".zig-toolchain/zig-0.15.2/bin/zig"
DRIVER_SOURCE = ROOT / ".zig-hot-unsupported-classify.zig"
DRIVER_BIN = ROOT / ".zig-cache/hot-unsupported-audit/classify_cli"


DRIVER = r'''const std = @import("std");
const classifier = @import("vendor/zig/lib/compiler/hot/classifier.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) return error.InvalidArgs;
    const source = try std.fs.cwd().readFileAllocOptions(
        allocator,
        args[1],
        100 * 1024 * 1024,
        null,
        .@"1",
        0,
    );
    const results = try classifier.classifyFile(allocator, source);
    const stdout = std.io.getStdOut().writer();
    for (results) |r| {
        try stdout.print("{s}\t{s}\t{s}\t{s}\t{s}\n", .{
            r.name,
            r.body_class.text(),
            if (r.reason) |reason| reason.text() else "",
            if (r.reason) |reason| if (reason.boundaryBucket()) |bucket| bucket.text() else "" else "",
            if (r.reason) |reason| if (reason.reloadGuidance()) |guidance| guidance.text() else "" else "",
        });
    }
}
'''


@dataclasses.dataclass(frozen=True)
class BlockedDecl:
    name: str
    reason: str
    boundary: str
    guidance: str


@dataclasses.dataclass(frozen=True)
class FileRank:
    project: str
    path: Path
    loc: int
    supported_functions: int
    value_cells: int
    invalidated: int
    blocked: tuple[BlockedDecl, ...]
    reasons: collections.Counter[str]

    @property
    def score(self) -> tuple[int, int, int]:
        return (len(self.blocked) * 10_000 + len(self.reasons) * 500 + self.loc, len(self.blocked), self.loc)


def ensure_driver() -> None:
    if not ZIG.exists():
        raise SystemExit(f"missing vendored Zig: {ZIG}")

    DRIVER_BIN.parent.mkdir(parents=True, exist_ok=True)
    DRIVER_SOURCE.write_text(DRIVER)
    try:
        subprocess.run(
            [str(ZIG), "build-exe", str(DRIVER_SOURCE), f"-femit-bin={DRIVER_BIN}"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )
    finally:
        try:
            DRIVER_SOURCE.unlink()
        except FileNotFoundError:
            pass


def classify_file(
    path: Path,
    timeout_seconds: float | None = None,
) -> tuple[int, int, int, tuple[BlockedDecl, ...], collections.Counter[str]]:
    output = subprocess.check_output(
        [str(DRIVER_BIN), str(path)],
        cwd=ROOT,
        text=True,
        stderr=subprocess.DEVNULL,
        timeout=timeout_seconds,
    )
    supported_functions = 0
    value_cells = 0
    invalidated = 0
    blocked: list[BlockedDecl] = []
    reasons: collections.Counter[str] = collections.Counter()

    for line in output.splitlines():
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        name, body_class, reason, boundary, guidance = parts[:5]
        if body_class == "interpreter-ready":
            supported_functions += 1
        elif body_class == "value-cell-ready":
            value_cells += 1
        elif body_class == "invalidate-dependents":
            invalidated += 1
        elif body_class == "native-only":
            normalized_reason = reason or "native-only"
            blocked.append(BlockedDecl(name, normalized_reason, boundary, guidance))
            reasons[normalized_reason] += 1

    return supported_functions, value_cells, invalidated, tuple(blocked), reasons


def zig_source_paths(root: Path) -> list[Path]:
    return [
        path
        for path in sorted(root.rglob("*.zig"))
        if not any(part in {".zig-cache", "zig-cache", "zig-out"} for part in path.parts)
    ]


def rank_file(
    project: str,
    path: Path,
    timeout_seconds: float | None,
) -> FileRank | None:
    try:
        supported, value_cells, invalidated, blocked, reasons = classify_file(path, timeout_seconds)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    if not blocked:
        return None
    loc = sum(1 for _ in path.open(errors="ignore"))
    return FileRank(
        project=project,
        path=path,
        loc=loc,
        supported_functions=supported,
        value_cells=value_cells,
        invalidated=invalidated,
        blocked=blocked,
        reasons=reasons,
    )


def scan_project(project: str, root: Path, jobs: int, timeout_seconds: float | None) -> list[FileRank]:
    ranks: list[FileRank] = []
    paths = zig_source_paths(root)
    if jobs <= 1 or len(paths) <= 1:
        for path in paths:
            rank = rank_file(project, path, timeout_seconds)
            if rank is not None:
                ranks.append(rank)
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
            futures = [
                executor.submit(rank_file, project, path, timeout_seconds)
                for path in paths
            ]
            for future in concurrent.futures.as_completed(futures):
                rank = future.result()
                if rank is not None:
                    ranks.append(rank)
    ranks.sort(key=lambda item: item.score, reverse=True)
    return ranks


def default_jobs() -> int:
    env_value = os.environ.get("HOT_UNSUPPORTED_AUDIT_JOBS")
    if env_value:
        try:
            return max(1, int(env_value))
        except ValueError:
            raise SystemExit(f"invalid HOT_UNSUPPORTED_AUDIT_JOBS: {env_value!r}")

    # Each worker is a separate Zig classifier process. Keep the default bounded
    # so the audit gets real wall-clock parallelism without surprising RAM use.
    return max(1, min(4, os.cpu_count() or 1))


def reason_summary(reasons: collections.Counter[str]) -> str:
    return ", ".join(f"`{reason}` {count}" for reason, count in reasons.most_common())


def examples(blocked: tuple[BlockedDecl, ...], limit: int = 6) -> str:
    return ", ".join(f"`{item.name}`" for item in blocked[:limit])


def emit_markdown(project: str, ranks: list[FileRank], limit: int) -> str:
    lines: list[str] = []
    lines.append(f"### {project}")
    lines.append("")
    lines.append("| Rank | File | Blocked functions | LOC | Dominant blockers | Example blocked functions |")
    lines.append("| --- | --- | ---: | ---: | --- | --- |")
    for index, rank in enumerate(ranks[:limit], 1):
        rel = rank.path.relative_to(ROOT)
        lines.append(
            f"| {index} | `{rel}` | {len(rank.blocked)} | {rank.loc} | {reason_summary(rank.reasons)} | {examples(rank.blocked)} |"
        )
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Rank hot-reload unsupported Zig files by classifier complexity.")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument(
        "--jobs",
        type=int,
        default=default_jobs(),
        help="number of classifier subprocesses to run concurrently (default: min(4, cpu count), or HOT_UNSUPPORTED_AUDIT_JOBS)",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=0,
        help="optional per-file classifier timeout; 0 disables the timeout",
    )
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be >= 1")

    timeout_seconds = args.timeout_seconds if args.timeout_seconds > 0 else None

    ensure_driver()
    projects = (
        ("Ghostty", ROOT / "src"),
        ("TigerBeetle", ROOT / "vendor/tigerbeetle/src"),
    )
    for project, path in projects:
        sys.stdout.write(emit_markdown(project, scan_project(project, path, args.jobs, timeout_seconds), args.limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
