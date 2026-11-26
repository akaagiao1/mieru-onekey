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
UPSTREAM = b'''for arg; do printf '%s\\n' "$arg"; done > "$BOOTSTRAP_ARGS"
if [[ ${1:-} == --help ]]; then printf 'upstream help\\n'; exit; fi
for arg; do
  if [[ $arg == --enable-timer && -f "$VOLTO_DEPLOY_ROOT/etc/volto/config.toml" &&
        ! -f ${BASH_SOURCE[0]:-} ]]; then
    printf 'no on-disk installer for timer\\n' >&2
    exit 1
  fi
done
if [[ ! -f "$VOLTO_DEPLOY_ROOT/etc/volto/config.toml" ]]; then
  cp "$BOOTSTRAP_CONFIG" "$VOLTO_DEPLOY_ROOT/etc/volto/config.toml"
  chmod 640 "$VOLTO_DEPLOY_ROOT/etc/volto/config.toml"
fi
'''


class TestVoltoListen(unittest.TestCase):
    def deploy(
        self,
        *,
        existing=None,
        initial=ORIGINAL,
        mode='',
        args=('--port', '27299'),
        extra_env=None,
        unreadable_conf_dir=False,
    ):
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
                    if [[ $MODE == check_rust_log && -n ${RUST_LOG:-} ]]; then
                        echo "unexpected RUST_LOG=$RUST_LOG" >&2
                        exit 1
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
            args_file = root / 'args'
            env = {
                **os.environ, 'PATH': f'{fake_bin}:{os.environ["PATH"]}',
                'VOLTO_DEPLOY_ROOT': dirname, 'FIXTURE': str(root / 'upstream.sh'),
                'BOOTSTRAP_CONFIG': str(root / 'initial.toml'), 'MODE': mode,
                'BOOTSTRAP_ARGS': str(args_file),
                'RESTARTS': str(restarts_file),
            }
            if extra_env:
                env.update(extra_env)
            if unreadable_conf_dir:
                config.parent.chmod(0o000)
            try:
                result = subprocess.run(
                    ['bash', wrapper, *args], capture_output=True, text=True,
                    env=env, timeout=10,
                )
            finally:
                if unreadable_conf_dir:
                    config.parent.chmod(0o755)
            files = sorted(p.name for p in config.parent.iterdir())
            self.assertEqual(['config.toml'] if config.exists() else [], files)
            if config.exists() and existing is None:
                self.assertEqual(0o640, config.stat().st_mode & 0o777)
            restarts = restarts_file.read_text().splitlines() if restarts_file.exists() else []
            upstream_args = args_file.read_text().splitlines() if args_file.exists() else None
            return result, config.read_text() if config.exists() else None, restarts, upstream_args

    def test_fresh_dual_stack_preserves_configuration(self):
        result, config, restarts, _ = self.deploy()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(DUAL_STACK, config)
        self.assertEqual(['listen = "[::]:27299"'], restarts)

    def test_dual_stack_unsets_caller_rust_log_for_check_config(self):
        result, config, restarts, _ = self.deploy(
            mode='check_rust_log', extra_env={'RUST_LOG': 'off'},
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(DUAL_STACK, config)
        self.assertEqual(['listen = "[::]:27299"'], restarts)

    def test_unsupported_dual_stack_retains_ipv4(self):
        for mode in ('ipv4', 'v6only', 'old'):
            with self.subTest(mode=mode):
                result, config, restarts, _ = self.deploy(mode=mode)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(ORIGINAL, config)
                self.assertEqual([], restarts)

    def test_existing_or_nondefault_listeners_are_preserved(self):
        custom = ORIGINAL.replace('0.0.0.0', '127.0.0.1')
        for opts, expected in [({'existing': ORIGINAL}, ORIGINAL), ({'initial': custom}, custom)]:
            with self.subTest(opts=opts):
                result, config, restarts, _ = self.deploy(**opts)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(expected, config)
                self.assertEqual([], restarts)

    def test_invalid_configuration_does_not_restart(self):
        result, config, restarts, _ = self.deploy(mode='invalid')
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(ORIGINAL, config)
        self.assertEqual([], restarts)

    def test_failed_restart_or_listener_verification_rolls_back(self):
        for mode in ('restart_failed', 'unverified'):
            with self.subTest(mode=mode):
                result, config, restarts, _ = self.deploy(mode=mode)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual(ORIGINAL, config)
                self.assertEqual(['listen = "[::]:27299"', 'listen = "0.0.0.0:27299"'], restarts)

    def test_help_does_not_install(self):
        result, config, restarts, upstream_args = self.deploy(args=('--help',))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('upstream help', result.stdout)
        self.assertIsNone(config)
        self.assertEqual([], restarts)
        self.assertEqual(['--help'], upstream_args)

    def test_update_forwards_release_options_and_keeps_existing_config(self):
        for flags in ((), ('--tag', 'v1.8.3', '--dry-run'), ('--tag', 'v1.8.5', '--force')):
            with self.subTest(flags=flags):
                result, config, restarts, upstream_args = self.deploy(
                    existing=DUAL_STACK, args=('update', *flags),
                )
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(DUAL_STACK, config)
                self.assertEqual([], restarts)
                self.assertEqual(list(flags), upstream_args)

    def test_update_allows_dry_run_with_tag_env(self):
        result, config, restarts, upstream_args = self.deploy(
            existing=DUAL_STACK, args=('update', '--dry-run'), extra_env={'TAG': 'v1.8.5'},
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(DUAL_STACK, config)
        self.assertEqual([], restarts)
        self.assertEqual(['--dry-run'], upstream_args)

    def test_update_rejects_missing_config_and_bad_options_before_download(self):
        cases = [
            (None, ('update',)),
            (ORIGINAL, ('update', '--port', '2443')),
            (ORIGINAL, ('update', '--tag', '--force')),
            (ORIGINAL, ('update', '--tag', '')),
            (ORIGINAL, ('update', '--tag', '1.8.5')),
            (ORIGINAL, ('update', '--dry-run')),
            (ORIGINAL, ('update', '--force')),
        ]
        for existing, args in cases:
            with self.subTest(args=args):
                result, config, restarts, upstream_args = self.deploy(existing=existing, args=args)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual(existing, config)
                self.assertEqual([], restarts)
                self.assertIsNone(upstream_args)

    def test_update_reports_sudo_hint_when_config_dir_unreadable(self):
        if os.geteuid() == 0:
            self.skipTest('root bypasses 0000 directory permissions')
        result, config, restarts, upstream_args = self.deploy(
            existing=DUAL_STACK, args=('update',), unreadable_conf_dir=True,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn('sudo', result.stderr)
        self.assertEqual(DUAL_STACK, config)
        self.assertEqual([], restarts)
        self.assertIsNone(upstream_args)

    def test_update_help_does_not_require_installation(self):
        result, config, restarts, upstream_args = self.deploy(args=('update', '--help'))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('volto-onekey.sh update', result.stdout)
        self.assertIsNone(config)
        self.assertEqual([], restarts)
        self.assertIsNone(upstream_args)

    def test_update_timer_and_direct_timer_can_reuse_verified_installer(self):
        for args in (('update', '--enable-timer'), ('--enable-timer',)):
            with self.subTest(args=args):
                result, config, restarts, upstream_args = self.deploy(
                    existing=DUAL_STACK, args=args,
                )
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(DUAL_STACK, config)
                self.assertEqual([], restarts)
                self.assertEqual(['--enable-timer'], upstream_args)

    def test_interruption_restores_ipv4_listener(self):
        result, config, restarts, _ = self.deploy(mode='interrupted')
        self.assertEqual(143, result.returncode)
        self.assertEqual(ORIGINAL, config)
        self.assertEqual(['listen = "[::]:27299"', 'listen = "0.0.0.0:27299"'], restarts)


if __name__ == '__main__':
    unittest.main(verbosity=2)
