import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


WRAPPER = Path(__file__).resolve().parents[1] / 'volto-onekey.sh'
ORIGINAL = '[server]\nlisten = "0.0.0.0:27299"\n\n[auth]\nusers = { demo = "fixture" }\n'
DUAL_STACK = ORIGINAL.replace('0.0.0.0', '[::]')
UPSTREAM = b'''if [[ ${1:-} == --help ]]; then printf 'upstream help\\n'; exit; fi
if [[ ! -f "$VOLTO_DEPLOY_ROOT/etc/volto/config.toml" ]]; then
  cp "$BOOTSTRAP_CONFIG" "$VOLTO_DEPLOY_ROOT/etc/volto/config.toml"
  chmod 640 "$VOLTO_DEPLOY_ROOT/etc/volto/config.toml"
fi
'''


class TestVoltoListen(unittest.TestCase):
    def deploy(self, *, existing=None, initial=ORIGINAL, mode='', args=('--port', '27299')):
        with tempfile.TemporaryDirectory() as dirname:
            root = Path(dirname)
            config = root / 'etc/volto/config.toml'
            config.parent.mkdir(parents=True)
            (root / 'run').mkdir()
            if existing is not None:
                config.write_text(existing)
            (root / 'upstream.sh').write_bytes(UPSTREAM)
            (root / 'initial.toml').write_text(initial)
            wrapper = root / 'wrapper.sh'
            # Keep the production checksum check in the test against the local fixture.
            source, replacements = re.subn(
                r'^upstream_sha256=[0-9a-f]{64}$',
                f'upstream_sha256={hashlib.sha256(UPSTREAM).hexdigest()}',
                WRAPPER.read_text(),
                flags=re.MULTILINE,
            )
            self.assertEqual(1, replacements)
            wrapper.write_text(source)
            fake_bin = root / 'usr/local/bin'
            fake_bin.mkdir(parents=True)
            commands = {
                'curl': 'while [[ $1 != --output ]]; do shift; done; cp "$FIXTURE" "$2"',
                'sysctl': 'if [[ $MODE == v6only ]]; then echo 1; else echo 0; fi',
                'ip': 'if [[ $MODE != ipv4 ]]; then echo "2: eth0 inet6 2001:db8::10/64 scope global"; fi',
                'flock': ':',
                'sleep': ':',
                'volto': r'''
                    if [[ $1 == --help ]]; then
                        if [[ $MODE != old ]]; then echo --check-config; fi
                        exit 0
                    fi
                    [[ $1 == --check-config && $2 == --config ]] &&
                        grep -qF 'listen = "[::]:27299"' "$3" && [[ $MODE != invalid ]]
                ''',
                'ss': r'''if [[ $MODE != unverified ]]; then echo 'UNCONN *:27299 users:(("volto",pid=10,fd=9)) v6only:0'; fi''',
                'systemctl': r'''
                    if [[ $1 == restart ]]; then
                        grep '^listen = ' "$VOLTO_DEPLOY_ROOT/etc/volto/config.toml" >> "$RESTARTS"
                        if [[ $MODE == restart_failed ]] && grep -qF '[::]' "$VOLTO_DEPLOY_ROOT/etc/volto/config.toml"; then exit 1; fi
                        if [[ $MODE == interrupted ]] && grep -qF '[::]' "$VOLTO_DEPLOY_ROOT/etc/volto/config.toml"; then
                            kill -TERM "$PPID"
                            exit 143
                        fi
                    fi
                ''',
            }
            for name, body in commands.items():
                command = fake_bin / name
                command.write_text('#!/bin/bash\n' + body + '\n')
                command.chmod(0o755)
            restarts_file = root / 'restarts'
            result = subprocess.run(['bash', wrapper, *args], capture_output=True, text=True,
                env={**os.environ, 'PATH': f'{fake_bin}:{os.environ["PATH"]}',
                     'VOLTO_DEPLOY_ROOT': dirname, 'FIXTURE': str(root / 'upstream.sh'),
                     'BOOTSTRAP_CONFIG': str(root / 'initial.toml'), 'MODE': mode,
                     'RESTARTS': str(restarts_file)}, timeout=10)
            files = sorted(p.name for p in config.parent.iterdir())
            self.assertEqual(['config.toml'] if config.exists() else [], files)
            if config.exists() and existing is None:
                self.assertEqual(0o640, config.stat().st_mode & 0o777)
            restarts = restarts_file.read_text().splitlines() if restarts_file.exists() else []
            return result, config.read_text() if config.exists() else None, restarts

    def test_fresh_dual_stack_preserves_configuration(self):
        result, config, restarts = self.deploy()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(DUAL_STACK, config)
        self.assertEqual(['listen = "[::]:27299"'], restarts)

    def test_unsupported_dual_stack_retains_ipv4(self):
        for mode in ('ipv4', 'v6only', 'old'):
            with self.subTest(mode=mode):
                result, config, restarts = self.deploy(mode=mode)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(ORIGINAL, config)
                self.assertEqual([], restarts)

    def test_existing_or_nondefault_listeners_are_preserved(self):
        custom = ORIGINAL.replace('0.0.0.0', '127.0.0.1')
        for opts, expected in [({'existing': ORIGINAL}, ORIGINAL), ({'initial': custom}, custom)]:
            with self.subTest(opts=opts):
                result, config, restarts = self.deploy(**opts)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(expected, config)
                self.assertEqual([], restarts)

    def test_invalid_configuration_does_not_restart(self):
        result, config, restarts = self.deploy(mode='invalid')
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(ORIGINAL, config)
        self.assertEqual([], restarts)

    def test_failed_restart_or_listener_verification_rolls_back(self):
        for mode in ('restart_failed', 'unverified'):
            with self.subTest(mode=mode):
                result, config, restarts = self.deploy(mode=mode)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual(ORIGINAL, config)
                self.assertEqual(['listen = "[::]:27299"', 'listen = "0.0.0.0:27299"'], restarts)

    def test_help_does_not_install(self):
        result, config, restarts = self.deploy(args=('--help',))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('upstream help', result.stdout)
        self.assertIsNone(config)
        self.assertEqual([], restarts)

    def test_interruption_restores_ipv4_listener(self):
        result, config, restarts = self.deploy(mode='interrupted')
        self.assertEqual(143, result.returncode)
        self.assertEqual(ORIGINAL, config)
        self.assertEqual(['listen = "[::]:27299"', 'listen = "0.0.0.0:27299"'], restarts)


if __name__ == '__main__':
    unittest.main(verbosity=2)
