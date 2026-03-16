#!/usr/bin/env python3
import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parent
MODULE_PATH = ROOT / "kill_hot_orphans.py"


def load_module():
    spec = importlib.util.spec_from_file_location("kill_hot_orphans", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError(f"failed to load module from {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    module = load_module()
    ps_output = "\n".join((
        "100 1 UE /Users/pfeodrippe/dev/ghostty-hot-0.15.2/.zig-cache-hot-diag/o/abcdef/build /Users/pfeodrippe/dev/zig-ghostty-hot-0.15.2/stage4-debug-cmake-implfix/bin/zig build run",
        "101 1 UE /Users/pfeodrippe/dev/zig-ghostty-hot-0.15.2/stage4-debug-cmake-implfix/bin/zig build run",
        "102 1 SN /Users/pfeodrippe/dev/ghostty-hot-0.15.2/.zig-cache-hot/o/abcdef/build /Users/pfeodrippe/dev/zig-ghostty-hot-0.15.2/stage4-debug-cmake-implfix/bin/zig build run",
        "103 77 S /Users/pfeodrippe/dev/zig-ghostty-hot-0.15.2/stage4-debug-cmake-implfix/bin/zig build run",
        "104 1 S /usr/bin/zig build",
        "105 1 S /usr/bin/python3 /Users/pfeodrippe/dev/ghostty-hot-0.15.2/tools/run_in_own_process_group.sh",
    ))

    rows = module.matching_rows_from_ps_output(ps_output)
    expected = [
        (
            100,
            1,
            "UE",
            "/Users/pfeodrippe/dev/ghostty-hot-0.15.2/.zig-cache-hot-diag/o/abcdef/build /Users/pfeodrippe/dev/zig-ghostty-hot-0.15.2/stage4-debug-cmake-implfix/bin/zig build run",
        ),
        (
            101,
            1,
            "UE",
            "/Users/pfeodrippe/dev/zig-ghostty-hot-0.15.2/stage4-debug-cmake-implfix/bin/zig build run",
        ),
        (
            102,
            1,
            "SN",
            "/Users/pfeodrippe/dev/ghostty-hot-0.15.2/.zig-cache-hot/o/abcdef/build /Users/pfeodrippe/dev/zig-ghostty-hot-0.15.2/stage4-debug-cmake-implfix/bin/zig build run",
        ),
    ]
    if rows != expected:
        raise AssertionError(f"unexpected orphan match set: {rows!r}")

    narrowed_rows = module.matching_rows_from_ps_output(
        ps_output,
        (
            "/Users/pfeodrippe/dev/ghostty-hot-0.15.2/.zig-cache-hot",
            "/Users/pfeodrippe/dev/ghostty-hot-0.15.2/.zig-global-cache-hot",
        ),
    )
    narrowed_expected = [
        (
            102,
            1,
            "SN",
            "/Users/pfeodrippe/dev/ghostty-hot-0.15.2/.zig-cache-hot/o/abcdef/build /Users/pfeodrippe/dev/zig-ghostty-hot-0.15.2/stage4-debug-cmake-implfix/bin/zig build run",
        ),
    ]
    if narrowed_rows != narrowed_expected:
        raise AssertionError(f"unexpected narrowed orphan match set: {narrowed_rows!r}")

    relative_rows = module.matching_rows_from_ps_output(
        ps_output,
        (
            ".zig-cache-hot",
            ".zig-global-cache-hot",
        ),
    )
    if relative_rows != narrowed_expected:
        raise AssertionError(f"unexpected relative orphan match set: {relative_rows!r}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
