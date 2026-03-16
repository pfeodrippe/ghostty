#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
import time


def _signal_child_group(child: subprocess.Popen[bytes], sig_num: int) -> bool:
    try:
        os.killpg(child.pid, sig_num)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        try:
            os.kill(child.pid, sig_num)
            return True
        except (ProcessLookupError, PermissionError):
            return False


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: run_in_own_process_group.sh <command> [args...]", file=sys.stderr)
        return 2

    child = subprocess.Popen(sys.argv[1:], start_new_session=True)

    def cleanup(sig_num, _frame):
        _signal_child_group(child, sig_num)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, cleanup)

    try:
        child_returncode = child.wait()
        if child_returncode < 0:
            return 128 + (-child_returncode)
        return child_returncode
    finally:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            if not _signal_child_group(child, sig):
                break
            time.sleep(0.2)
        try:
            child.wait(timeout=1)
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
