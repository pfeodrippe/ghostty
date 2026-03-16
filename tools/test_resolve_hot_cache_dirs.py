#!/usr/bin/env python3
import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parent
MODULE_PATH = ROOT / "resolve_hot_cache_dirs.py"


def load_module():
    spec = importlib.util.spec_from_file_location("resolve_hot_cache_dirs", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError(f"failed to load module from {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    module = load_module()

    cache_dir = "/tmp/.zig-cache-hot"
    global_cache_dir = "/tmp/.zig-global-cache-hot"

    chosen = module.choose_cache_dirs(cache_dir, global_cache_dir, lambda _: set())
    if chosen != (cache_dir, global_cache_dir):
        raise AssertionError(f"unexpected base cache choice: {chosen!r}")

    def holder_lookup(paths):
        holders = {
            (cache_dir, global_cache_dir): {92730},
            (
                f"{cache_dir}-recover-1",
                f"{global_cache_dir}-recover-1",
            ): {81234},
        }
        return holders.get(tuple(paths), set())

    chosen = module.choose_cache_dirs(cache_dir, global_cache_dir, holder_lookup)
    expected = (
        f"{cache_dir}-recover-2",
        f"{global_cache_dir}-recover-2",
    )
    if chosen != expected:
        raise AssertionError(f"unexpected recovery cache choice: {chosen!r}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
