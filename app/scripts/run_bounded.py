#!/usr/bin/env python3
"""Bound a noninteractive build command and clean up its process group."""
import os
import re
import signal
import subprocess
import sys


def main():
    if len(sys.argv) < 3 or not re.fullmatch(r"[0-9]{1,4}", sys.argv[1]) or not 1 <= int(sys.argv[1]) <= 3600:
        print("Usage: run_bounded.py SECONDS(1..3600) COMMAND [ARG...]", file=sys.stderr)
        return 2
    state = {"process": None, "signal": None}
    def kill_group():
        process = state["process"]
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    def interrupt(signum, _frame):
        # Record interrupts during Popen too; kill immediately after it returns.
        state["signal"] = signum
        kill_group()
    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    process = subprocess.Popen(sys.argv[2:], start_new_session=True)
    state["process"] = process
    if state["signal"] is not None:
        kill_group()
    try:
        result = process.wait(timeout=int(sys.argv[1]))
    except subprocess.TimeoutExpired:
        kill_group()
        process.wait()
        print("Build command timed out: " + sys.argv[2], file=sys.stderr)
        return 124
    if state["signal"] is not None:
        return 128 + state["signal"]
    return result if result >= 0 else 128 - result


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("Build command failed: " + str(error), file=sys.stderr)
        sys.exit(1)
