import hashlib
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import tempfile
import unittest


WRAPPER = Path(__file__).resolve().parents[1] / 'volto-onekey.sh'
ORIGINAL = (
    '[server]\n'
    'listen = "0.0.0.0:27299"\n'
    'cert = "/etc/volto/cert.pem"\n'
    '#ech_key = "/etc/volto/ech.pem"\n'
    '\n'
    '[auth]\n'
    'users = [\n'
    '  { username = "surge", password = "secret-password" },\n'
    ']\n'
    '\n'
    '[limits]\n'
    'initial_mtu = 1242\n'
    '\n'
    '[security]\n'
    '#expected_sni = []\n'
    '#require_ech = false\n'
)
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
  printf 'DUMMY CERT\\n' > "$VOLTO_DEPLOY_ROOT/etc/volto/cert.pem"
  printf 'certificate: sha256 Fingerprint=AA:BB:CC:DD\\n\\n'
  printf 'Surge policy line (replace the address if this host is behind a relay):\\n\\n'
  printf '  volto = masque, 203.0.113.10, 27299, sni=volto.internal, server-cert-fingerprint-sha256=AA:BB:CC:DD, username=surge, password=UPSTREAM_PASS\\n\\n'
  printf 'Security notes:\\n  * mock note\\n'
fi
'''


def _run_in_pty(cmd, env, timeout=15):
    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=slave_fd,
        stderr=subprocess.PIPE,
        env=env,
        close_fds=True,
    )
    os.close(slave_fd)
    chunks = []
    try:
        while True:
            ready, _, _ = select.select([master_fd], [], [], timeout)
            if not ready:
                proc.kill()
                raise subprocess.TimeoutExpired(cmd, timeout)
            try:
                data = os.read(master_fd, 4096)
            except OSError:
                break
            if not data:
                break
            chunks.append(data)
        stderr = proc.stderr.read().decode('utf-8', errors='replace')
        proc.wait(timeout=timeout)
    finally:
        os.close(master_fd)
        proc.stderr.close()
    stdout = b''.join(chunks).decode('utf-8', errors='replace').replace('\r\n', '\n')
    return subprocess.CompletedProcess(cmd, proc.returncode, stdout, stderr)


class TestVoltoListen(unittest.TestCase):
    def deploy(
        self,
        *,
        existing=None,
        existing_cert=False,
        existing_ech=None,
        initial=ORIGINAL,
        mode='',
        args=('--port', '27299'),
        extra_env=None,
        unreadable_conf_dir=False,
        use_tty=False,
    ):
        with tempfile.TemporaryDirectory() as dirname:
            root = Path(dirname)
            config = root / 'etc/volto/config.toml'
            config.parent.mkdir(parents=True)
            (root / 'run').mkdir()
            if existing is not None:
                config.write_text(existing)
            if existing_cert:
                (config.parent / 'cert.pem').write_text('DUMMY CERT\n')
            if existing_ech is not None:
                (config.parent / 'ech.pem').write_text(existing_ech)
            (root / 'upstream.sh').write_bytes(UPSTREAM)
            (root / 'initial.toml').write_text(initial)
            wrapper = root / 'wrapper.sh'
            # Keep the production checksum check in the test against the local fixture.
            source, replacements = re.subn(
                r'^upstream_sha256=[0-9a-f]{64}$',
                f'upstream_sha256={hashlib.sha256(UPSTREAM).hexdigest()}',
                WRAPPER.read_text(encoding='utf-8'),
                flags=re.MULTILINE,
            )
            self.assertEqual(1, replacements)
            wrapper.write_text(source, encoding='utf-8', newline='\n')
            fake_bin = root / 'usr/local/bin'
            fake_bin.mkdir(parents=True)
            commands = {
                'curl': 'while [[ $1 != --output ]]; do shift; done; cp "$FIXTURE" "$2"',
                'hostname': 'if [[ $1 == -I ]]; then echo "203.0.113.10 2001:db8::10"; fi',
                'openssl': r'''
                    case "$*" in
                        *-fingerprint*-sha256*)
                            printf 'sha256 Fingerprint=AA:BB:CC:DD\n'
                            ;;
                        *-ext*subjectAltName*)
                            printf 'X509v3 Subject Alternative Name:\n    DNS:volto.internal\n'
                            ;;
                    esac
                ''',
                'sysctl': r'''
                    if [[ $1 == -n ]]; then
                        case $2 in
                            net.ipv6.bindv6only)
                                if [[ $MODE == v6only ]]; then echo 1; else echo 0; fi
                                ;;
                            net.core.rmem_max|net.core.wmem_max)
                                if [[ $MODE == high_buf ]]; then echo 33554432; else echo 212992; fi
                                ;;
                        esac
                    elif [[ $1 == -w ]]; then
                        printf '%s\n' "$2" >> "$SYSCTL_WRITES"
                    fi
                ''',
                'ip': 'if [[ $MODE != ipv4 ]]; then echo "2: eth0 inet6 2001:db8::10/64 scope global"; fi',
                'flock': ':',
                'sleep': ':',
                'chgrp': ':',
                'volto': r'''
                    if [[ $1 == --help ]]; then
                        if [[ $MODE != old ]]; then
                            echo --check-config
                            if [[ $MODE != no_ech_bin ]]; then
                                echo ech-keygen
                            fi
                        fi
                        exit 0
                    fi
                    if [[ $1 == ech-keygen ]]; then
                        pub="" out=""
                        shift
                        while (( $# )); do
                            case $1 in
                                --public-name) pub="$2"; shift 2 ;;
                                --out) out="$2"; shift 2 ;;
                                *) shift ;;
                            esac
                        done
                        printf '%s\n' "$pub" > "$ECH_PUB_FILE"
                        printf 'PRIVATE KEY\nECHCONFIG %s\n' "$pub" > "$out"
                        printf 'AEX+MOCK+ECHCONFIG+LIST\n'
                        exit 0
                    fi
                    if [[ $1 == ech-config ]]; then
                        [[ -r ${2:-} ]] || exit 1
                        printf 'AEX+MOCK+ECHCONFIG+LIST\n'
                        exit 0
                    fi
                    if [[ $MODE == check_rust_log && -n ${RUST_LOG:-} ]]; then
                        echo "unexpected RUST_LOG=$RUST_LOG" >&2
                        exit 1
                    fi
                    [[ $1 == --check-config && $2 == --config ]] && [[ $MODE != invalid ]]
                ''',
                'ss': r'''if [[ $MODE != unverified ]]; then echo 'UNCONN *:27299 users:(("volto",pid=10,fd=9)) v6only:0'; fi''',
                'systemctl': r'''
                    if [[ $1 == restart ]]; then
                        grep '^listen = ' "$VOLTO_DEPLOY_ROOT/etc/volto/config.toml" >> "$RESTARTS"
                        if [[ $MODE == restart_failed ]] && grep -qE '^expected_sni =|^listen = "\[::\]' "$VOLTO_DEPLOY_ROOT/etc/volto/config.toml"; then exit 1; fi
                        if [[ $MODE == interrupted ]] && grep -qE '^expected_sni =|^listen = "\[::\]' "$VOLTO_DEPLOY_ROOT/etc/volto/config.toml"; then
                            kill -TERM "$PPID"
                            exit 143
                        fi
                    fi
                ''',
            }
            for name, body in commands.items():
                command = fake_bin / name
                command.write_text('#!/bin/bash\n' + body + '\n', encoding='utf-8', newline='\n')
                command.chmod(0o755)
            restarts_file = root / 'restarts'
            args_file = root / 'args'
            sysctl_writes = root / 'sysctl_writes'
            ech_pub_file = root / 'ech_pub'
            env = {
                **os.environ, 'PATH': f'{fake_bin}:{os.environ["PATH"]}',
                'VOLTO_DEPLOY_ROOT': dirname, 'FIXTURE': str(root / 'upstream.sh'),
                'BOOTSTRAP_CONFIG': str(root / 'initial.toml'), 'MODE': mode,
                'BOOTSTRAP_ARGS': str(args_file),
                'RESTARTS': str(restarts_file),
                'SYSCTL_WRITES': str(sysctl_writes),
                'ECH_PUB_FILE': str(ech_pub_file),
            }
            if extra_env:
                env.update(extra_env)
            if unreadable_conf_dir:
                config.parent.chmod(0o000)
            try:
                if use_tty:
                    result = _run_in_pty(['bash', str(wrapper), *args], env=env, timeout=15)
                else:
                    result = subprocess.run(
                        ['bash', str(wrapper), *args], capture_output=True, text=True,
                        env=env, timeout=15,
                    )
            finally:
                if unreadable_conf_dir:
                    config.parent.chmod(0o755)
            files = sorted(p.name for p in config.parent.iterdir())
            if config.exists() and existing is None:
                self.assertEqual(0o640, config.stat().st_mode & 0o777)
            restarts = restarts_file.read_text().splitlines() if restarts_file.exists() else []
            upstream_args = args_file.read_text().splitlines() if args_file.exists() else None
            sysctl_conf = root / 'etc/sysctl.d/90-volto-udp-buffers.conf'
            return {
                'result': result,
                'config': config.read_text() if config.exists() else None,
                'config_path': str(config),
                'files': files,
                'restarts': restarts,
                'upstream_args': upstream_args,
                'sysctl_conf': sysctl_conf.read_text() if sysctl_conf.exists() else None,
                'sysctl_writes': sysctl_writes.read_text().splitlines() if sysctl_writes.exists() else [],
                'ech_pub': ech_pub_file.read_text().strip() if ech_pub_file.exists() else None,
                'ech_mode': (config.parent / 'ech.pem').stat().st_mode & 0o777 if (config.parent / 'ech.pem').exists() else None,
            }

    def test_fresh_install_hardens_dual_stack_sni_ech_and_udp_buffers(self):
        out = self.deploy()
        self.assertEqual(0, out['result'].returncode, out['result'].stderr)
        cfg = out['config']
        self.assertIn('listen = "[::]:27299"', cfg)
        self.assertIn('initial_mtu = 1200', cfg)
        self.assertIn('expected_sni = ["volto.internal"]', cfg)
        self.assertIn('require_ech = true', cfg)
        self.assertRegex(cfg, r'ech_key = ".*/etc/volto/ech\.pem"')
        self.assertEqual(['cert.pem', 'config.toml', 'ech.pem'], out['files'])
        self.assertEqual(0o640, out['ech_mode'])
        self.assertEqual('cloudflare-ech.com', out['ech_pub'])
        expected_line = (
            '  volto = masque, 203.0.113.10, 27299, sni=volto.internal, '
            'server-cert-fingerprint-sha256=AA:BB:CC:DD, '
            'ech-config=AEX+MOCK+ECHCONFIG+LIST, username=surge, '
            f'password=<as in {out["config_path"]}>'
        )
        self.assertIn(expected_line, out['result'].stdout)
        self.assertEqual(1, out['result'].stdout.count('volto = masque,'))
        self.assertNotIn('UPSTREAM_PASS', out['result'].stdout)
        self.assertIn('Security notes:', out['result'].stdout)
        self.assertIn('net.core.rmem_max = 4194304', out['sysctl_conf'])
        self.assertIn('net.core.wmem_max = 4194304', out['sysctl_conf'])
        self.assertEqual(['net.core.rmem_max=4194304', 'net.core.wmem_max=4194304'], out['sysctl_writes'])
        self.assertEqual(['listen = "[::]:27299"'], out['restarts'])

    def test_fresh_install_prints_complete_surge_line_with_password_on_tty(self):
        out = self.deploy(use_tty=True)
        self.assertEqual(0, out['result'].returncode, out['result'].stderr)
        expected_line = (
            '  volto = masque, 203.0.113.10, 27299, sni=volto.internal, '
            'server-cert-fingerprint-sha256=AA:BB:CC:DD, '
            'ech-config=AEX+MOCK+ECHCONFIG+LIST, username=surge, '
            'password=secret-password'
        )
        self.assertIn(expected_line, out['result'].stdout)
        self.assertEqual(1, out['result'].stdout.count('volto = masque,'))
        self.assertNotIn('UPSTREAM_PASS', out['result'].stdout)

    def test_high_udp_buffers_are_not_lowered(self):
        out = self.deploy(mode='high_buf')
        self.assertEqual(0, out['result'].returncode, out['result'].stderr)
        self.assertIsNone(out['sysctl_conf'])
        self.assertEqual([], out['sysctl_writes'])

    def test_no_ech_flag_keeps_sni_gate_and_strips_wrapper_args(self):
        out = self.deploy(args=('--port', '27299', '--sni', 'edge.example', '--no-ech'))
        self.assertEqual(0, out['result'].returncode, out['result'].stderr)
        self.assertEqual(['--port', '27299', '--sni', 'edge.example'], out['upstream_args'])
        self.assertEqual(['cert.pem', 'config.toml'], out['files'])
        self.assertIn('expected_sni = ["edge.example"]', out['config'])
        self.assertNotIn('\nrequire_ech = true', out['config'])
        self.assertNotIn('\nech_key =', out['config'])
        self.assertIn('UPSTREAM_PASS', out['result'].stdout)
        self.assertNotIn('ech-config=', out['result'].stdout)

    def test_custom_ech_public_name_and_sni(self):
        out = self.deploy(args=('--port', '27299', '--sni', 'proxy.example', '--ech-public-name', 'public.example'))
        self.assertEqual(0, out['result'].returncode, out['result'].stderr)
        self.assertEqual(['--port', '27299', '--sni', 'proxy.example'], out['upstream_args'])
        self.assertEqual('public.example', out['ech_pub'])
        self.assertIn('expected_sni = ["proxy.example"]', out['config'])
        self.assertIn('sni=proxy.example, server-cert-fingerprint-sha256=AA:BB:CC:DD, ech-config=AEX+MOCK+ECHCONFIG+LIST', out['result'].stdout)

    def test_dual_stack_unsets_caller_rust_log_for_check_config(self):
        out = self.deploy(mode='check_rust_log', extra_env={'RUST_LOG': 'off'})
        self.assertEqual(0, out['result'].returncode, out['result'].stderr)
        self.assertIn('listen = "[::]:27299"', out['config'])

    def test_unsupported_dual_stack_retains_ipv4_but_still_hardens_sni_and_ech(self):
        for mode in ('ipv4', 'v6only'):
            with self.subTest(mode=mode):
                out = self.deploy(mode=mode)
                self.assertEqual(0, out['result'].returncode, out['result'].stderr)
                self.assertIn('listen = "0.0.0.0:27299"', out['config'])
                self.assertIn('initial_mtu = 1242', out['config'])
                self.assertIn('expected_sni = ["volto.internal"]', out['config'])
                self.assertIn('require_ech = true', out['config'])

    def test_old_binary_skips_post_install_changes(self):
        out = self.deploy(mode='old')
        self.assertEqual(0, out['result'].returncode, out['result'].stderr)
        self.assertEqual(ORIGINAL, out['config'])
        self.assertEqual(['cert.pem', 'config.toml'], out['files'])
        self.assertEqual([], out['restarts'])
        self.assertEqual(1, out['result'].stdout.count('volto = masque,'))
        self.assertNotIn('ech-config=', out['result'].stdout)

    def test_existing_config_is_preserved_without_rewriting(self):
        out = self.deploy(existing=ORIGINAL)
        self.assertEqual(0, out['result'].returncode, out['result'].stderr)
        self.assertEqual(ORIGINAL, out['config'])
        self.assertEqual(['config.toml'], out['files'])
        self.assertEqual([], out['restarts'])
        self.assertIsNone(out['sysctl_conf'])

    def test_invalid_configuration_does_not_restart_and_cleans_ech_key(self):
        out = self.deploy(mode='invalid')
        self.assertNotEqual(0, out['result'].returncode)
        self.assertEqual(ORIGINAL, out['config'])
        self.assertEqual(['cert.pem', 'config.toml'], out['files'])
        self.assertEqual([], out['restarts'])

    def test_failed_restart_or_listener_verification_rolls_back_config_and_ech(self):
        for mode in ('restart_failed', 'unverified'):
            with self.subTest(mode=mode):
                out = self.deploy(mode=mode)
                self.assertNotEqual(0, out['result'].returncode)
                self.assertEqual(ORIGINAL, out['config'])
                self.assertEqual(['cert.pem', 'config.toml'], out['files'])
                self.assertEqual(['listen = "[::]:27299"', 'listen = "0.0.0.0:27299"'], out['restarts'])

    def test_show_subcommand_outputs_complete_surge_line_without_download(self):
        hardened = ORIGINAL.replace('#ech_key = "/etc/volto/ech.pem"', 'ech_key = "/etc/volto/ech.pem"').replace(
            '#expected_sni = []', 'expected_sni = ["edge.example"]'
        )
        out_non_tty = self.deploy(
            existing=hardened,
            existing_cert=True,
            existing_ech='PRIVATE KEY\nECHCONFIG\n',
            args=('show',),
        )
        self.assertEqual(0, out_non_tty['result'].returncode, out_non_tty['result'].stderr)
        self.assertIsNone(out_non_tty['upstream_args'])
        self.assertIn(
            '  volto = masque, 203.0.113.10, 27299, sni=edge.example, '
            'server-cert-fingerprint-sha256=AA:BB:CC:DD, '
            'ech-config=AEX+MOCK+ECHCONFIG+LIST, username=surge, '
            f'password=<as in {out_non_tty["config_path"]}>',
            out_non_tty['result'].stdout,
        )

        out_tty = self.deploy(
            existing=hardened,
            existing_cert=True,
            existing_ech='PRIVATE KEY\nECHCONFIG\n',
            args=('show',),
            use_tty=True,
        )
        self.assertEqual(0, out_tty['result'].returncode, out_tty['result'].stderr)
        self.assertIsNone(out_tty['upstream_args'])
        self.assertIn(
            '  volto = masque, 203.0.113.10, 27299, sni=edge.example, '
            'server-cert-fingerprint-sha256=AA:BB:CC:DD, '
            'ech-config=AEX+MOCK+ECHCONFIG+LIST, username=surge, '
            'password=secret-password',
            out_tty['result'].stdout,
        )

    def test_show_help_and_error_cases(self):
        out_help = self.deploy(args=('show', '--help'))
        self.assertEqual(0, out_help['result'].returncode, out_help['result'].stderr)
        self.assertIn('volto-onekey.sh show', out_help['result'].stdout)
        self.assertIsNone(out_help['upstream_args'])

        out_missing = self.deploy(args=('show',))
        self.assertNotEqual(0, out_missing['result'].returncode)
        self.assertIsNone(out_missing['upstream_args'])

        out_extra = self.deploy(existing=ORIGINAL, args=('show', '--extra'))
        self.assertNotEqual(0, out_extra['result'].returncode)
        self.assertIsNone(out_extra['upstream_args'])

    def test_help_does_not_install(self):
        out = self.deploy(args=('--help',))
        self.assertEqual(0, out['result'].returncode, out['result'].stderr)
        self.assertIn('upstream help', out['result'].stdout)
        self.assertIn('--no-ech', out['result'].stdout)
        self.assertIn('volto-onekey.sh show', out['result'].stdout)
        self.assertIsNone(out['config'])
        self.assertIsNone(out['sysctl_conf'])
        self.assertEqual([], out['sysctl_writes'])
        self.assertEqual([], out['restarts'])
        self.assertEqual(['--help'], out['upstream_args'])

    def test_update_forwards_release_options_and_keeps_existing_config(self):
        for flags in ((), ('--tag', 'v1.8.3', '--dry-run'), ('--tag', 'v1.8.5', '--force')):
            with self.subTest(flags=flags):
                out = self.deploy(existing=ORIGINAL, args=('update', *flags))
                self.assertEqual(0, out['result'].returncode, out['result'].stderr)
                self.assertEqual(ORIGINAL, out['config'])
                self.assertEqual([], out['restarts'])
                self.assertEqual(list(flags), out['upstream_args'])

    def test_update_allows_dry_run_with_tag_env(self):
        out = self.deploy(existing=ORIGINAL, args=('update', '--dry-run'), extra_env={'TAG': 'v1.8.5'})
        self.assertEqual(0, out['result'].returncode, out['result'].stderr)
        self.assertEqual(ORIGINAL, out['config'])
        self.assertEqual([], out['restarts'])
        self.assertEqual(['--dry-run'], out['upstream_args'])

    def test_update_rejects_missing_config_and_bad_options_before_download(self):
        cases = [
            (None, ('update',)),
            (ORIGINAL, ('update', '--port', '2443')),
            (ORIGINAL, ('update', '--no-ech')),
            (ORIGINAL, ('update', '--tag', '--force')),
            (ORIGINAL, ('update', '--tag', '')),
            (ORIGINAL, ('update', '--tag', '1.8.5')),
            (ORIGINAL, ('update', '--dry-run')),
            (ORIGINAL, ('update', '--force')),
        ]
        for existing, args in cases:
            with self.subTest(args=args):
                out = self.deploy(existing=existing, args=args)
                self.assertNotEqual(0, out['result'].returncode)
                self.assertEqual(existing, out['config'])
                self.assertEqual([], out['restarts'])
                self.assertIsNone(out['upstream_args'])

    def test_update_reports_sudo_hint_when_config_dir_unreadable(self):
        if os.geteuid() == 0:
            self.skipTest('root bypasses 0000 directory permissions')
        out = self.deploy(existing=ORIGINAL, args=('update',), unreadable_conf_dir=True)
        self.assertNotEqual(0, out['result'].returncode)
        self.assertIn('sudo', out['result'].stderr)
        self.assertEqual(ORIGINAL, out['config'])
        self.assertEqual([], out['restarts'])
        self.assertIsNone(out['upstream_args'])

    def test_update_help_does_not_require_installation(self):
        out = self.deploy(args=('update', '--help'))
        self.assertEqual(0, out['result'].returncode, out['result'].stderr)
        self.assertIn('volto-onekey.sh update', out['result'].stdout)
        self.assertIsNone(out['config'])
        self.assertEqual([], out['restarts'])
        self.assertIsNone(out['upstream_args'])

    def test_update_timer_and_direct_timer_can_reuse_verified_installer(self):
        for args in (('update', '--enable-timer'), ('--enable-timer',)):
            with self.subTest(args=args):
                out = self.deploy(existing=ORIGINAL, args=args)
                self.assertEqual(0, out['result'].returncode, out['result'].stderr)
                self.assertEqual(ORIGINAL, out['config'])
                self.assertEqual([], out['restarts'])
                self.assertEqual(['--enable-timer'], out['upstream_args'])

    def test_interruption_restores_original_config_and_removes_ech(self):
        out = self.deploy(mode='interrupted')
        self.assertEqual(143, out['result'].returncode)
        self.assertEqual(ORIGINAL, out['config'])
        self.assertEqual(['cert.pem', 'config.toml'], out['files'])
        self.assertEqual(['listen = "[::]:27299"', 'listen = "0.0.0.0:27299"'], out['restarts'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
