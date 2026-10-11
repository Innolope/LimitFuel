#!/usr/bin/env python3
"""Explicit release action. notarytool reads credentials from Keychain."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile

APP_DIR = Path(__file__).resolve().parents[1]
MAX_OUTPUT = 1024 * 1024


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(args, timeout=120, notary=False):
    # Spool output to bound memory. Never echo raw auth/notary diagnostics.
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        process = subprocess.Popen(args, stdout=out, stderr=err, start_new_session=True)
        try:
            process.wait(timeout=timeout)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            if notary:
                raise RuntimeError("Notarization outcome unknown; Apple may still be processing. Inspect notarytool history before retrying.")
            raise RuntimeError("External command interrupted or timed out: " + args[0])
        if process.returncode != 0:
            if notary:
                raise RuntimeError("Notarization submission failed; outcome unknown. Inspect notarytool history before retrying.")
            raise RuntimeError("External command failed: " + args[0])
        out.seek(0)
        err.seek(0)
        output, errors = out.read(MAX_OUTPUT + 1), err.read(MAX_OUTPUT + 1)
        require(len(output) <= MAX_OUTPUT and len(errors) <= MAX_OUTPUT, "External command output exceeds 1MiB")
        return output.decode("utf-8"), errors.decode("utf-8")


def text_setting(name, default):
    value = os.environ.get(name, default)
    require(bool(value) and len(value) <= 1024 and not any(c in value for c in "\r\n\0"), "Invalid " + name)
    return value


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def release():
    identity = text_setting("DEVELOPER_ID", "Developer ID Application: Innolope LLC (MQD26CY5MA)")
    team = re.search(r"\(([A-Z0-9]{10})\)$", identity)
    require(team is not None and identity.startswith("Developer ID Application: "), "DEVELOPER_ID must be a Developer ID Application identity with a team ID")
    profile = text_setting("NOTARY_PROFILE", "LimitFuel")
    timeout = text_setting("NOTARY_TIMEOUT_SECONDS", "1200")
    require(re.fullmatch(r"[0-9]{1,4}", timeout) is not None and 1 <= int(timeout) <= 3600, "Invalid NOTARY_TIMEOUT_SECONDS (expected 1..3600)")
    lock = APP_DIR / ".release-lock"
    try:
        lock.mkdir()
    except FileExistsError:
        raise RuntimeError("Another build/release owns .release-lock; do not remove an active lock")
    stage = None
    try:
        app = APP_DIR / "build/LimitFuel.app"
        require(app.is_dir(), "Build the signed app first")
        with (app / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        version, build = info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")
        for value in (version, build):
            require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,63}", value) is not None, "Invalid bundle version/build")
        provenance_path = app / "Contents/Resources/build-info.json"
        require(provenance_path.stat().st_size <= MAX_OUTPUT, "Oversized build provenance")
        provenance = json.loads(provenance_path.read_text())
        require(isinstance(provenance, dict) and provenance.get("dirty") is False, "Release requires clean build provenance")
        commit = provenance.get("commit")
        require(isinstance(commit, str) and re.fullmatch(r"[a-f0-9]{40}", commit) is not None, "Invalid source commit")
        head, _ = command(["git", "-C", str(APP_DIR.parent), "rev-parse", "HEAD"])
        status, _ = command(["git", "-C", str(APP_DIR.parent), "status", "--porcelain", "--untracked-files=normal"])
        require(head.strip() == commit and not status.strip(), "Source checkout changed or is dirty; rebuild from a clean checkout")
        command(["codesign", "--verify", "--deep", "--strict", str(app)])
        _, details = command(["codesign", "-dv", "--verbose=4", str(app)])
        require("Signature=adhoc" not in details and "(runtime)" in details and re.search(r"^TeamIdentifier=" + re.escape(team.group(1)) + r"$", details, re.M), "App must have hardened runtime and a matching Developer ID team signature")
        dist = APP_DIR / "dist"
        dist.mkdir(exist_ok=True)
        destination = dist / ("LimitFuel-" + version + "-" + build)
        require(not destination.exists(), "Release already exists; increment version/build or preserve it elsewhere")
        stage = Path(tempfile.mkdtemp(prefix=".limitfuel-", dir=dist))
        contents = stage / "contents"
        contents.mkdir()
        shutil.copytree(app, contents / "LimitFuel.app", symlinks=True)
        (contents / "Applications").symlink_to("/Applications")
        dmg = stage / "LimitFuel-Installer.dmg"
        command(["hdiutil", "create", "-volname", "LimitFuel", "-srcfolder", str(contents), "-format", "UDZO", str(dmg)])
        command(["codesign", "--force", "--timestamp", "--sign", identity, str(dmg)])
        command(["codesign", "--verify", "--strict", str(dmg)])
        print("Submitting DMG to Apple; waiting for Accepted status…", flush=True)
        result, _ = command(["xcrun", "notarytool", "submit", str(dmg), "--keychain-profile", profile, "--output-format", "json", "--wait", "--timeout", timeout + "s"], timeout=int(timeout), notary=True)
        result = json.loads(result)
        require(isinstance(result, dict) and result.get("status") == "Accepted", "Apple did not accept this submission")
        submission = result.get("id")
        require(isinstance(submission, str) and re.fullmatch(r"[a-fA-F0-9-]{36}", submission) is not None, "Missing/invalid notarization submission ID")
        print("Accepted submission: " + submission, flush=True)
        command(["xcrun", "stapler", "staple", str(dmg)])
        command(["xcrun", "stapler", "validate", str(dmg)])
        command(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", str(dmg)])
        record = dict(commit=commit, version=version, build=build, notarizationID=submission, sha256=sha256_file(dmg))
        (stage / "release-info.json").write_text(json.dumps(record, indent=2) + "\n")
        shutil.rmtree(contents)
        stage.rename(destination)
        stage = None
        print("Verified notarized installer: " + str(destination / dmg.name))
    finally:
        if stage is not None:
            shutil.rmtree(stage)
        lock.rmdir()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    try:
        release()
    except (Exception, KeyboardInterrupt) as error:
        print("Release stopped: " + str(error), file=sys.stderr)
        sys.exit(1)
