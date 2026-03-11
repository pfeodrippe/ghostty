#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
import time


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: run_in_own_process_group.sh <command> [args...]", file=sys.stderr)
        return 2

    child = subprocess.Popen(sys.argv[1:], start_new_session=True)

    def cleanup(sig_num, _frame):
        try:
            os.killpg(child.pid, sig_num)
        except ProcessLookupError:
            pass

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, cleanup)

    try:
        return child.wait()
    finally:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(child.pid, sig)
            except ProcessLookupError:
                break
            time.sleep(0.2)
        try:
            child.wait(timeout=1)
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
