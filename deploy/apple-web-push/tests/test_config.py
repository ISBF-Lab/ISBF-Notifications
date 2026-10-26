import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("push_config", ROOT / "config.py")
config = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(config)

FIXTURE = b'''# peer comments are preserved
env:
  http_proxy: "http://example.invalid:8080" # unrelated
  no_proxy: "localhost,internal.invalid" # peer exclusion
  NO_PROXY: '127.0.0.1'
  DISCOURSE_HOSTNAME: example.invalid
hooks:
  after_code:
    - exec:
        cmd:
          - echo peer-plugin-install
  after_web:
    - exec:
        cmd: echo peer-web
'''


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.hook = config.hook_for((ROOT / "install.py").read_bytes(), (ROOT / "env-policy.sh").read_bytes())

    def test_peer_preservation_idempotence_and_exact_inverse(self):
        result = config.patch_config(FIXTURE, self.hook)
        self.assertEqual(config.patch_config(result, self.hook), result)
        self.assertIn(b'# unrelated', result)
        self.assertIn(b'# peer exclusion', result)
        self.assertIn(b'echo peer-plugin-install', result)
        self.assertIn(b'echo peer-web', result)
        self.assertEqual(config.rollback_config(result, FIXTURE, result, self.hook), FIXTURE)
        value = config.load(result)[1]
        self.assertEqual(value['hooks']['after_code'][-1], self.hook)
        self.assertEqual(value['env']['no_proxy'], 'localhost,internal.invalid,web.push.apple.com')
        self.assertEqual(value['env']['NO_PROXY'], '127.0.0.1,web.push.apple.com')

    def test_rollback_preserves_later_peer_edits(self):
        after = config.patch_config(FIXTURE, self.hook)
        peer = after.replace(b'echo peer-web', b'echo newer-peer-web')
        self.assertEqual(config.rollback_config(peer, FIXTURE, after, self.hook),
                         FIXTURE.replace(b'echo peer-web', b'echo newer-peer-web'))

    def test_rollback_refuses_owned_field_conflicts(self):
        after = config.patch_config(FIXTURE, self.hook)
        peer = after.replace(b'127.0.0.1,web.push.apple.com', b'127.0.0.1,web.push.apple.com,new-peer')
        with self.assertRaises(ValueError):
            config.rollback_config(peer, FIXTURE, after, self.hook)

    def test_ambiguous_configuration_and_unknown_hook_refused(self):
        for fixture in [FIXTURE.replace(b'  NO_PROXY:', b'  no_proxy:'),
                        FIXTURE.replace(b"  NO_PROXY: '127.0.0.1'", b'  NO_PROXY: null'),
                        FIXTURE.replace(b"  NO_PROXY: '127.0.0.1'", b'')]:
            with self.subTest(fixture=fixture), self.assertRaises(ValueError):
                config.patch_config(fixture, self.hook)
        after = config.patch_config(FIXTURE, self.hook)
        altered = config.hook_for(b'different installer', b'different policy')
        with self.assertRaises(ValueError):
            config.patch_config(after, altered)

    def test_aliases_and_anchors_refused(self):
        for source in [FIXTURE.replace(b'env:\n', b'env: &shared\n') + b'mirrored: *shared\n',
                       FIXTURE.replace(b'env:\n', b'env: &shared\n')]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                config.patch_config(source, self.hook)

    def test_exact_tokens_and_literal_metacharacters(self):
        for value in ['web.push.apple.com', 'A,WEB.PUSH.APPLE.COM, B', 'A web.push.apple.com B']:
            self.assertEqual(config.add_host(value), value)
        value = '$(false);`false`,.web.push.apple.com,web.push.apple.com.evil'
        self.assertEqual(config.add_host(value), value + ',web.push.apple.com')


if __name__ == '__main__':
    unittest.main()
