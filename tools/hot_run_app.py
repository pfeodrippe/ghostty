#!/usr/bin/env python3

import argparse
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


TEMP_APP_PREFIX = "/tmp/ghostty-hot-run-app."


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Launch a fresh hot Ghostty app instance.")
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--app-bundle", required=True)
    parser.add_argument("--resources-dir", required=True)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--hot-compiler", required=True)
    parser.add_argument("--hot-workspace", required=True)
    parser.add_argument("--hot-lib-dir", required=True)
    parser.add_argument("--hot-manifest", required=True)
    parser.add_argument("--run-args", default="")
    parser.add_argument("--startup-timeout", type=float, default=60.0)
    return parser.parse_args()


def ghostty_rows() -> list[tuple[int, str]]:
    out = subprocess.check_output(["ps", "-Ao", "pid=,command="], text=True)
    rows: list[tuple[int, str]] = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        pid_s, cmd = parts
        if "/Ghostty.app/Contents/MacOS/ghostty" not in cmd:
            continue
        try:
            pid = int(pid_s)
        except ValueError:
            continue
        rows.append((pid, cmd))
    return rows


def select_old_rows(repo_root: Path) -> list[tuple[int, str]]:
    repo_root_str = str(repo_root)
    rows: list[tuple[int, str]] = []
    for pid, cmd in ghostty_rows():
        if repo_root_str in cmd or TEMP_APP_PREFIX in cmd:
            rows.append((pid, cmd))
    return rows


def signal_rows(rows: list[tuple[int, str]], sig: int) -> None:
    if not rows:
        return
    subprocess.run(["kill", f"-{sig}", *[str(pid) for pid, _ in rows]], check=False)


def live_rows(rows: list[tuple[int, str]]) -> list[tuple[int, str]]:
    survivors: list[tuple[int, str]] = []
    for pid, cmd in rows:
        try:
            os.kill(pid, 0)
        except OSError:
            continue
        survivors.append((pid, cmd))
    return survivors


def cleanup_old_processes(repo_root: Path) -> list[tuple[int, str]]:
    rows = select_old_rows(repo_root)
    if not rows:
        return []
    for sig in (signal.SIGTERM, signal.SIGKILL):
        signal_rows(rows, sig)
        time.sleep(1.0)
        rows = live_rows(rows)
        if not rows:
            return []
    return rows


def cleanup_old_temp_dirs() -> None:
    tmp_root = Path("/tmp")
    for path in tmp_root.glob("ghostty-hot-run-app.*"):
        shutil.rmtree(path, ignore_errors=True)


def run_hot_probe(port_file: Path) -> bool:
    repo_root = Path(__file__).resolve().parent.parent
    helper = repo_root / "tools" / "hot_nrepl"
    if not helper.exists():
        return False
    completed = subprocess.run(
        [str(helper), "--timeout", "2", "--port-file", str(port_file), "--op", "current-generation"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return completed.returncode == 0


def read_port(port_file: Path) -> str | None:
    try:
        data = port_file.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None
    return data or None


def tail_text(path: Path, limit: int = 120) -> str:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        return ""
    return "\n".join(lines[-limit:])


def write_state(repo_root: Path, payload: dict[str, object]) -> None:
    state_path = repo_root / ".zig-hot" / "hot-run-state.json"
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    repo_root = Path(args.repo_root).resolve()
    app_bundle = Path(args.app_bundle).resolve()
    resources_dir = Path(args.resources_dir).resolve()
    port_file = Path(args.port_file).resolve()
    hot_workspace = Path(args.hot_workspace).resolve()
    hot_manifest = Path(args.hot_manifest).resolve()
    hot_lib_dir = Path(args.hot_lib_dir).resolve()
    hot_compiler = Path(args.hot_compiler).resolve()

    survivors = cleanup_old_processes(repo_root)
    cleanup_old_temp_dirs()
    if port_file.exists():
        port_file.unlink()

    instance_root = Path(tempfile.mkdtemp(prefix="ghostty-hot-run-app.", dir="/tmp"))
    log_path = instance_root / "ghostty.log"
    copied_app = instance_root / app_bundle.name
    subprocess.run(["cp", "-R", str(app_bundle), str(instance_root)], check=True)

    child_env = os.environ.copy()
    child_env.update(
        {
            "GHOSTTY_LOG": "stderr,macos",
            "GHOSTTY_MAC_LAUNCH_SOURCE": "zig_run",
            "GHOSTTY_RESOURCES_DIR": str(resources_dir),
            "ZIG_HOT_COMPILER": str(hot_compiler),
            "ZIG_HOT_WORKSPACE": str(hot_workspace),
            "ZIG_HOT_ZIG_LIB_DIR": str(hot_lib_dir),
            "ZIG_HOT_MANIFEST": str(hot_manifest),
        }
    )

    argv = [
        str(copied_app / "Contents" / "MacOS" / "ghostty"),
        *shlex.split(args.run_args),
    ]

    with log_path.open("wb") as log_file:
        proc = subprocess.Popen(
            argv,
            cwd=repo_root,
            env=child_env,
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )

    write_state(
        repo_root,
        {
            "pid": proc.pid,
            "instance_root": str(instance_root),
            "log_path": str(log_path),
            "app": str(copied_app),
            "run_args": args.run_args,
        },
    )

    deadline = time.monotonic() + args.startup_timeout
    port: str | None = None
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            break
        port = read_port(port_file)
        if port and run_hot_probe(port_file):
            subprocess.run(
                ["osascript", "-e", 'tell application "Ghostty" to activate'],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            warning = ""
            if survivors:
                pid_list = ", ".join(str(pid) for pid, _ in survivors)
                warning = f"\nwarning: old Ghostty processes survived teardown: {pid_list}"
            print(
                f"launched hot Ghostty pid={proc.pid} port={port} bundle={copied_app}{warning}"
            )
            return 0
        time.sleep(0.25)

    proc.poll()
    if proc.returncode is None:
        proc.terminate()
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2.0)

    sys.stderr.write("error: hot-run launch did not reach a responsive hot runtime\n")
    if survivors:
        pid_list = ", ".join(str(pid) for pid, _ in survivors)
        sys.stderr.write(f"warning: old Ghostty processes survived teardown: {pid_list}\n")
    log_tail = tail_text(log_path)
    if log_tail:
        sys.stderr.write("--- ghostty log tail ---\n")
        sys.stderr.write(log_tail)
        if not log_tail.endswith("\n"):
            sys.stderr.write("\n")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
