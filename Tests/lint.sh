#!/bin/sh
set -eu
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO"
bash -n app/build.sh
bash -n app/create_dmg.sh
python3 -c 'import ast,pathlib; [ast.parse(p.read_text()) for p in pathlib.Path("app/scripts").glob("*.py")]'
sh -n Tests/run.sh
sh -n Tests/lint.sh
plutil -lint app/Info.plist
plutil -lint app/Diagnostics.plist
plutil -lint app/SentryPrivacy-Info.plist
python3 -m json.tool .codex/quality-gates.json > /dev/null
python3 -m json.tool website/fork-latest.json > /dev/null
GIT_TOOL=/Library/Developer/CommandLineTools/usr/bin/git
if [ ! -x "$GIT_TOOL" ]; then GIT_TOOL=git; fi
"$GIT_TOOL" diff --check
"$GIT_TOOL" diff --cached --check
