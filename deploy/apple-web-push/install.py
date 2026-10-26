#!/usr/bin/env python3
"""Install the Apple Web Push environment policy; never restart services.

The launcher transformation is byte preserving and deliberately conservative.
Unsupported launchers need human review rather than a shell rewrite.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile


POLICY_PATH = Path("/etc/isbf/apple-web-push/env-policy.sh")
MARKER = b"ISBF APPLE WEB PUSH"
BLOCK = (
    b"# BEGIN ISBF APPLE WEB PUSH v1\n"
    b". /etc/isbf/apple-web-push/env-policy.sh\n"
    b"# END ISBF APPLE WEB PUSH v1\n"
)
SHEBANG = re.compile(rb"#![ \t]*(/bin/(?:ba)?sh|/usr/bin/(?:ba)?sh)[ \t]*\n")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def _split(original):
    if not isinstance(original, bytes):
        raise ValueError("launcher must be bytes")
    if b"\r" in original or b"\0" in original or not original.endswith(b"\n"):
        raise ValueError("launcher requires LF terminated text")
    match = SHEBANG.match(original)
    if not match:
        raise ValueError("unsupported launcher interpreter")
    return original[:match.end()], original[match.end():]


def _unmanaged(original):
    header, body = _split(original)
    managed = body.startswith(BLOCK)
    if managed:
        body = body[len(BLOCK):]
    if MARKER in body:
        raise ValueError("unknown or nested managed markers")
    return header, body, managed


def _validate_body(body):
    try:
        text = body.decode("utf-8").replace("\\\n", "")
        lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>")
        lexer.whitespace_split = True
        tokens = list(lexer)
    except (UnicodeError, ValueError):
        raise ValueError("unsupported launcher text") from None
    # Conservative rejection also covers export/unset/read/indirect rewrites.
    if re.search(r"\b(?:no_proxy|NO_PROXY)\b", " ".join(tokens)):
        raise ValueError("launcher references proxy bypass variables")
    if any(token.rsplit("/", 1)[-1] in {".", "source", "envdir", "eval"} for token in tokens):
        raise ValueError("launcher loads or evaluates additional environment")
    for index, token in enumerate(tokens):
        command = token.rsplit("/", 1)[-1]
        # Inspect the remainder conservatively, including quoted/escaped options.
        options = []
        for following in tokens[index + 1:]:
            if following in {";", "&&", "||", "|", "&", ")"}:
                break
            if following.startswith("-"):
                options.append(following)
        if command == "env" and any(
            option == "--ignore-environment" or
            (not option.startswith("--") and "i" in option) for option in options
        ):
            raise ValueError("launcher clears environment")
        if command == "chpst" and any(
            not option.startswith("--") and "e" in option for option in options
        ):
            raise ValueError("launcher loads envdir")
        if command in {"sh", "bash"} and any(
            not option.startswith("--") and "c" in option for option in options
        ):
            raise ValueError("launcher executes a dynamic shell")


def patch_run(original):
    """Insert one recognized block immediately after the shebang."""
    header, body, _ = _unmanaged(original)
    _validate_body(body)
    return header + BLOCK + body


def unpatch_run(original):
    """Remove only the exact recognized block, preserving all original bytes."""
    header, body, _ = _unmanaged(original)
    return header + body


def _protected(path, directory=False):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise ValueError("target ancestry must be root owned and protected")
    if directory and not stat.S_ISDIR(info.st_mode):
        raise ValueError("target ancestry is not a directory")
    if not directory and not stat.S_ISREG(info.st_mode):
        raise ValueError("target is not a regular file")
    return info


def _ancestry(path, create=False, allow_missing=False):
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("absolute normalized path required")
    for item in reversed((path,) + tuple(path.parents)):
        try:
            _protected(item, directory=True)
        except FileNotFoundError:
            if allow_missing:
                return
            if not create:
                raise ValueError("target directory missing") from None
            item.mkdir(mode=0o755)
            _protected(item, directory=True)
            _sync_directory(item.parent)


def _sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _read(path, protected=False):
    # O_NOFOLLOW closes the final-component symlink race on Linux.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("source is not a regular file")
        if protected and (info.st_uid != 0 or info.st_mode & 0o022):
            raise ValueError("target must be root owned and protected")
        return stream.read(), info


def _atomic(path, data, mode, uid, gid):
    descriptor, name = tempfile.mkstemp(prefix=".apple-web-push-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchown(stream.fileno(), uid, gid)
            os.fchmod(stream.fileno(), stat.S_IMODE(mode))
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        _sync_directory(path.parent)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def _syntax(data, shells):
    for shell in shells:
        executable = "/bin/" + shell
        if not Path(executable).is_file():
            raise ValueError("required shell validator unavailable")
        checked = subprocess.run([executable, "-n"], input=data, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, check=False,
                                 env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
        if checked.returncode:
            raise ValueError("shell syntax validation failed")


def install(run_path, policy_source, expected_policy_sha, expected_run_sha=None):
    if os.geteuid() != 0:
        raise ValueError("installer requires root")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_policy_sha):
        raise ValueError("invalid expected policy digest")
    _ancestry(run_path.parent)
    original, info = _read(run_path, protected=True)
    if expected_run_sha and digest(original) != expected_run_sha.lower():
        raise ValueError("launcher digest mismatch")
    policy, _ = _read(policy_source)
    if digest(policy) != expected_policy_sha.lower():
        raise ValueError("policy digest mismatch")
    patched = patch_run(original)
    _syntax(policy, ("sh", "bash"))
    _syntax(patched, ("bash" if b"bash" in patched.split(b"\n", 1)[0] else "sh",))
    # Inspect before creating anything, and never overwrite an unknown policy.
    _ancestry(POLICY_PATH.parent, allow_missing=True)
    existing = None
    if POLICY_PATH.exists() or POLICY_PATH.is_symlink():
        existing, _ = _read(POLICY_PATH, protected=True)
        if existing != policy:
            raise ValueError("unrecognized existing policy")
    _ancestry(POLICY_PATH.parent, create=True)
    if existing is None:
        _atomic(POLICY_PATH, policy, 0o644, 0, 0)
    if patched != original:
        # Recheck the launcher before replacing the validated original.
        current, current_info = _read(run_path, protected=True)
        if current != original or (current_info.st_mode, current_info.st_uid, current_info.st_gid) != (info.st_mode, info.st_uid, info.st_gid):
            raise ValueError("launcher changed during installation")
        _atomic(run_path, patched, info.st_mode, info.st_uid, info.st_gid)
    return {"policy_sha256": digest(policy), "run_before_sha256": digest(original),
            "run_after_sha256": digest(patched), "policy_changed": existing is None,
            "run_changed": patched != original}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    command = sub.add_parser("install")
    command.add_argument("--run-path", type=Path, default=Path("/etc/service/unicorn/run"))
    command.add_argument("--policy-source", type=Path, required=True)
    command.add_argument("--expected-policy-sha", "--expected-sha", required=True)
    command.add_argument("--expected-run-sha")
    args = parser.parse_args()
    try:
        result = install(args.run_path, args.policy_source, args.expected_policy_sha,
                         args.expected_run_sha)
    except (ValueError, OSError):
        # Never echo paths, launcher contents, subprocess diagnostics or environment.
        print(json.dumps({"ok": False}), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
