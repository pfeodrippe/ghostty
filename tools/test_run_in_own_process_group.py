#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent
WRAPPER = ROOT / "run_in_own_process_group.sh"


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="ghostty-wrapper-test-") as tmp:
        tmpdir = Path(tmp)
        pid_file = tmpdir / "child.pid"
        child_code = textwrap.dedent(
            f"""
            import os
            import pathlib
            import time

            pathlib.Path({pid_file.as_posix()!r}).write_text(str(os.getpid()))
            while True:
                time.sleep(0.1)
            """
        )

        proc = subprocess.Popen(
            [sys.executable, str(WRAPPER), sys.executable, "-c", child_code],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        deadline = time.time() + 10
        child_pid = None
        while time.time() < deadline:
            if pid_file.exists():
                child_pid = int(pid_file.read_text())
                break
            time.sleep(0.1)

        if child_pid is None:
            proc.kill()
            stdout, stderr = proc.communicate(timeout=5)
            raise AssertionError(
                f"child pid file was not created\\nstdout:\\n{stdout}\\nstderr:\\n{stderr}"
            )

        proc.send_signal(signal.SIGTERM)
        stdout, stderr = proc.communicate(timeout=10)

        if proc.returncode not in (0, 128 + signal.SIGTERM):
            raise AssertionError(f"unexpected wrapper exit code: {proc.returncode}\\nstderr:\\n{stderr}")
        if "PermissionError" in stderr or "Traceback" in stderr:
            raise AssertionError(f"wrapper emitted traceback\\nstderr:\\n{stderr}")
        if process_exists(child_pid):
            raise AssertionError(f"child process still exists: {child_pid}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
