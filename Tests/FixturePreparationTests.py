#!/usr/bin/env python3
"""Spec-only acceptance test for silent, side-effect-free native preparation."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest


class FixturePreparationTests(unittest.TestCase):
    def test_preparation_is_silent_marker_free_and_repeatable(self):
        source = Path(FIXTURE_EXECUTABLE).resolve(strict=True)
        with tempfile.TemporaryDirectory(prefix="fixture-prepare-spec-") as directory:
            executable = Path(directory) / "fixture"
            shutil.copy2(source, executable)
            markers = [Path(str(executable) + suffix) for suffix in
                       (".parent.pid", ".child.pid", ".ready.time")]
            for attempt in range(2):
                with self.subTest(attempt=attempt + 1):
                    process = subprocess.Popen(
                        [str(executable), "--prepare"],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        start_new_session=True,
                    )
                    try:
                        stdout, stderr = process.communicate(timeout=30)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.communicate()
                        self.fail("--prepare did not complete within 30 seconds")
                    finally:
                        # Own the entire process group, including any stray descendants.
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    self.assertEqual(process.returncode, 0)
                    self.assertEqual(stdout, b"")
                    self.assertEqual(stderr, b"")
                    for marker in markers:
                        self.assertFalse(marker.exists(), f"unexpected marker: {marker}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: FixturePreparationTests.py FIXTURE_EXECUTABLE")
    FIXTURE_EXECUTABLE = sys.argv.pop(1)
    unittest.main()
