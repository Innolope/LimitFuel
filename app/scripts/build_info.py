#!/usr/bin/env python3
"""Record source provenance inside the signature; no credentials are accessed."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def main():
    if sys.argv[1] == "--check-identity":
        identity = sys.argv[2]
        if len(identity) > 1024 or any(c in identity for c in "\r\n\0") or not re.fullmatch(
                r"Developer ID Application: .+ \([A-Z0-9]{10}\)", identity):
            raise ValueError("Invalid DEVELOPER_ID")
        return
    repo = Path(__file__).resolve().parents[2]
    git = "/Library/Developer/CommandLineTools/usr/bin/git"
    if not os.path.isfile(git):
        git = "git"
    def read(*args):
        return subprocess.check_output([git, "-C", str(repo), *args], timeout=30).decode().strip()
    info = dict(commit=read("rev-parse", "HEAD"),
                dirty=bool(read("status", "--porcelain", "--untracked-files=normal")))
    path = Path(sys.argv[1]) / "Contents/Resources/build-info.json"
    if "--verify" in sys.argv[2:]:
        if json.loads(path.read_text()) != info:
            raise ValueError("Source checkout changed during compilation; rebuild")
    else:
        path.write_text(json.dumps(info, indent=2) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Build provenance failed: " + str(error), file=sys.stderr)
        sys.exit(1)
