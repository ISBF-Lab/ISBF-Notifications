"""Local fixtures only: no service access and no real environment logging."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("apple_push_install", ROOT / "install.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)
HOST = "web.push.apple.com"


def available_shell(name):
    override = os.environ.get("TEST_" + name.upper())
    return override or shutil.which(name)


class PolicyTests(unittest.TestCase):
    def shell_result(self, values, shell="sh"):
        executable = available_shell(shell)
        if not executable:
            self.skipTest(shell + " unavailable")
        # Run from the policy directory, avoiding Windows/MSYS absolute path conversion.
        script = r'''
set -- 'first arg' 'second;arg'
IFS=':='
before_options=$-
before_ifs=$IFS
before_pwd=$PWD
before_args="$*"
trap ':' TERM
before_traps=$(trap)
. ./env-policy.sh
. ./env-policy.sh
[ "$before_options" = "$-" ] && [ "$before_ifs" = "$IFS" ] &&
[ "$before_pwd" = "$PWD" ] && [ "$before_args" = "$*" ] &&
[ "$before_traps" = "$(trap)" ] || exit 91
[ "$(set | sed -n '/^_isbf/p')" = '' ] || exit 92
printf '%s\000%s' "$no_proxy" "$NO_PROXY"
'''
        environment = {key: value for key, value in os.environ.items()
                       if key.lower() != "no_proxy"}
        environment.update(values)
        result = subprocess.run([executable, "-c", script], cwd=ROOT, env=environment,
                                capture_output=True, check=True)
        return tuple(result.stdout.decode().split("\0"))

    def test_absence_and_empty_use_presence_precedence(self):
        # Windows process environments are case insensitive; run the full matrix
        # inside a shell rather than supplying colliding Windows environment keys.
        executable = available_shell("sh")
        if not executable:
            self.skipTest("sh unavailable")
        fixtures = [
            ("unset no_proxy NO_PROXY", HOST, HOST),
            ("unset no_proxy; NO_PROXY=upper", "upper," + HOST, "upper," + HOST),
            ("no_proxy=lower; unset NO_PROXY", "lower," + HOST, "lower," + HOST),
            ("no_proxy=''; NO_PROXY=upper", HOST, "upper," + HOST),
            ("no_proxy=lower; NO_PROXY=''", "lower," + HOST, HOST),
            ("no_proxy=lower; NO_PROXY=upper", "lower," + HOST, "upper," + HOST),
        ]
        for setup, lower, upper in fixtures:
            with self.subTest(setup=setup):
                command = setup + "; . ./env-policy.sh; . ./env-policy.sh; "
                command += "printf '%s\\000%s' \"$no_proxy\" \"$NO_PROXY\""
                result = subprocess.run([executable, "-c", command], cwd=ROOT,
                                        capture_output=True, check=True)
                self.assertEqual(tuple(result.stdout.decode().split("\0")), (lower, upper))

    def test_exact_case_insensitive_comma_or_whitespace_tokens(self):
        for value in [HOST, "WEB.PUSH.Apple.Com", "a," + HOST + ",b",
                      "a\t" + HOST + " b", "a\n" + HOST + "\rb",
                      "a\v" + HOST + "\fb"]:
            with self.subTest(value=value):
                self.assertEqual(self.shell_result({"no_proxy": value}), (value, value))
        for value in ["x" + HOST, HOST + ".evil", "." + HOST, HOST + ":443"]:
            with self.subTest(value=value):
                self.assertEqual(self.shell_result({"no_proxy": value}),
                                 (value + "," + HOST,) * 2)

    def test_metacharacters_are_literal_and_shell_state_is_unchanged(self):
        value = "$(exit 88);`exit 89` * ? [abc] ' \" \\ a,b"
        for shell in ["sh", "bash"]:
            with self.subTest(shell=shell):
                self.assertEqual(self.shell_result({"no_proxy": value}, shell),
                                 (value + "," + HOST,) * 2)

    def test_shell_syntax(self):
        for name in ["sh", "bash"]:
            executable = available_shell(name)
            if executable:
                subprocess.run([executable, "-n", "env-policy.sh"], cwd=ROOT, check=True)


class LauncherTests(unittest.TestCase):
    ORIGINAL = b"#!/bin/bash\n# launcher\ncd /var/www/discourse\nexec chpst -u discourse bundle exec unicorn -c config/unicorn.conf.rb\n"

    def test_exact_reversal_and_idempotence(self):
        for original in [self.ORIGINAL, b"#!/bin/sh\n\nexec unicorn\n"]:
            with self.subTest(original=original):
                patched = installer.patch_run(original)
                self.assertEqual(installer.patch_run(patched), patched)
                self.assertEqual(installer.unpatch_run(patched), original)
                self.assertEqual(installer.unpatch_run(original), original)
                first, rest = original.split(b"\n", 1)
                self.assertEqual(patched, first + b"\n" + installer.BLOCK + rest)

    def test_refuses_unknown_or_nested_blocks(self):
        for body in [installer.BLOCK * 2, installer.BLOCK.replace(b"v1", b"v2"),
                     b"# BEGIN ISBF APPLE WEB PUSH\n", b"echo hi\n" + installer.BLOCK]:
            for function in [installer.patch_run, installer.unpatch_run]:
                with self.subTest(body=body, function=function):
                    with self.assertRaises(ValueError):
                        function(b"#!/bin/bash\n" + body)

    def test_refuses_unsafe_launchers(self):
        scripts = [b"#!/bin/python\nexec unicorn\n", b"#!/bin/bash", b"#!/bin/bash\r\nexec unicorn\r\n",
                   b"#!/usr/bin/env bash\nexec unicorn\n"]
        bodies = [b"export no_proxy=a", b"NO_PROXY=b exec unicorn", b"unset no_proxy",
                  b"env -i unicorn", b"env '-i' unicorn", b"env -u irrelevant -i unicorn",
                  b"/usr/bin/env --ignore-environment unicorn",
                  b"chpst -e /etc/env unicorn", b"/usr/bin/envdir /etc/env unicorn",
                  b". /etc/environment", b"true;. /etc/environment", b"source /etc/profile",
                  b"eval something", b"bash -c 'exec unicorn'", b"bash -lc 'exec unicorn'",
                  b"no_\\\nproxy=a"]
        scripts += [b"#!/bin/bash\n" + body + b"\n" for body in bodies]
        for script in scripts:
            with self.subTest(script=script):
                with self.assertRaises(ValueError):
                    installer.patch_run(script)


@unittest.skipUnless(hasattr(os, "geteuid") and os.geteuid() == 0,
                     "root ownership checks require a Linux root fixture")
class InstallerTests(unittest.TestCase):
    def setUp(self):
        # Linux CI uses /root: /tmp is intentionally rejected as writable ancestry.
        self.temporary = tempfile.TemporaryDirectory(prefix="apple-push-test-", dir="/root")
        self.root = Path(self.temporary.name)
        self.run = self.root / "run"
        self.run.write_bytes(LauncherTests.ORIGINAL)
        self.run.chmod(0o750)
        self.policy = self.root / "source.sh"
        self.policy.write_bytes((ROOT / "env-policy.sh").read_bytes())
        self.target = self.root / "isbf" / "apple-web-push" / "env-policy.sh"
        self.override = patch.object(installer, "POLICY_PATH", self.target)
        self.override.start()

    def tearDown(self):
        self.override.stop()
        self.temporary.cleanup()

    def apply(self, **kwargs):
        return installer.install(self.run, self.policy, installer.digest(self.policy.read_bytes()), **kwargs)

    def test_install_atomic_metadata_and_idempotence(self):
        before = self.run.stat()
        first = self.apply(expected_run_sha=installer.digest(self.run.read_bytes()))
        second = self.apply()
        self.assertTrue(first["run_changed"])
        self.assertTrue(first["policy_changed"])
        self.assertFalse(second["run_changed"])
        self.assertFalse(second["policy_changed"])
        after = self.run.stat()
        self.assertEqual((before.st_uid, before.st_gid, before.st_mode),
                         (after.st_uid, after.st_gid, after.st_mode))
        self.assertEqual(self.target.read_bytes(), self.policy.read_bytes())
        self.assertEqual(installer.unpatch_run(self.run.read_bytes()), LauncherTests.ORIGINAL)
        self.assertEqual(set(json.loads(json.dumps(second))),
                         {"policy_sha256", "run_before_sha256", "run_after_sha256",
                          "policy_changed", "run_changed"})

    def test_refuses_launcher_metadata_change(self):
        real_read = installer._read
        reads = 0

        def changed_read(path, protected=False):
            nonlocal reads
            if path == self.run:
                reads += 1
                if reads == 2:
                    self.run.chmod(0o700)
            return real_read(path, protected)

        with patch.object(installer, "_read", side_effect=changed_read):
            with self.assertRaises(ValueError):
                self.apply()
        self.assertEqual(self.run.read_bytes(), LauncherTests.ORIGINAL)
        self.assertEqual(self.run.stat().st_mode & 0o777, 0o700)

    def test_refuses_unknown_policy_and_bad_hash_before_run_write(self):
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b"unknown\n")
        with self.assertRaises(ValueError):
            self.apply()
        self.assertEqual(self.run.read_bytes(), LauncherTests.ORIGINAL)
        self.target.unlink()
        with self.assertRaises(ValueError):
            installer.install(self.run, self.policy, "0" * 64)
        self.assertFalse(self.target.exists())

    def test_refuses_symlink_and_writable_ancestry(self):
        real = self.root / "real-run"
        self.run.rename(real)
        self.run.symlink_to(real)
        with self.assertRaises(OSError):
            self.apply()
        self.run.unlink()
        real.rename(self.run)
        self.root.chmod(0o777)
        with self.assertRaises(ValueError):
            self.apply()


if __name__ == "__main__":
    unittest.main()
