import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'mieru-onekey.sh'


class TestMieruUpdate(unittest.TestCase):
    def run_update(
        self,
        *,
        os_id='debian',
        installed='3.39.0',
        release_version='3.40.0',
        mode='',
        version='',
        args=(),
        busybox_tools=False,
        tar_arcname='mita',
        uppercase_crlf_checksum=False,
        restorecon_exit=0,
        latest_tag='v3.40.0',
        pre_create_staging=None,
        remove_binary=False,
        symlink_in_tar=False,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commands = root / 'bin'
            commands.mkdir()
            binary = commands / 'mita'
            os_release = root / 'os-release'
            os_release.write_text(f'ID={os_id}\n')
            script = root / SCRIPT.name
            script.write_text(SCRIPT.read_text()
                              .replace('/usr/bin/mita', str(binary))
                              .replace('/etc/os-release', str(os_release)))
            state = root / 'state'
            state.mkdir()
            config_files = {
                root / 'server.conf.pb': b'\x01\x09 existing binary config\x00',
                root / 'client.txt': b'client configuration and timestamp\n',
                state / 'state.env': b'PORT="8965"\nTAG="custom"\n',
            }
            for path, data in config_files.items():
                path.write_bytes(data)
                path.chmod(0o600)
            proxy_state = root / 'proxy-state'
            proxy_state.write_text('IDLE\n' if mode == 'idle' else 'RUNNING\n')

            def executable(path, body):
                path.write_text('#!/bin/bash\n' + body + '\n')
                path.chmod(0o755)

            def fake_mita(mita_version):
                return f'''
case "$1" in
  version) echo '2026-11-25 00:00:00.000 INFO {mita_version}' >&2 ;;
  status)
    if [[ $MODE == unhealthy && {mita_version} == {release_version} ]]; then echo 'proxy unavailable'; exit 1; fi
    printf 'mita server status is "%s"\\n' "$(cat "$PROXY_STATE")" ;;
  *) echo "unexpected mita command: $1" >&2; exit 1 ;;
esac
'''

            executable(binary, fake_mita(installed))
            release_binary = root / 'mita'
            executable(release_binary, fake_mita(release_version))
            release = root / 'release.tar.gz'
            with tarfile.open(release, 'w:gz') as archive:
                if symlink_in_tar:
                    info = tarfile.TarInfo(name='mita')
                    info.type = tarfile.SYMTYPE
                    info.linkname = '/etc/passwd'
                    archive.addfile(info)
                else:
                    archive.add(release_binary, arcname=tar_arcname)
            digest = hashlib.sha256(release.read_bytes()).hexdigest() if mode != 'bad_digest' else '0' * 64
            if uppercase_crlf_checksum:
                digest = digest.upper()
            checksum = root / 'checksum.txt'
            if uppercase_crlf_checksum:
                checksum.write_bytes(f'{digest}\r\n'.encode())
            else:
                checksum.write_text(f'{digest}  release.tar.gz\n')
            events = root / 'events'
            events.touch()

            staging_dir = Path(f'{binary}.update')
            if pre_create_staging == 'stale':
                staging_dir.mkdir(mode=0o700)
                (staging_dir / 'pid').write_text('999999\n')
            elif pre_create_staging == 'live':
                staging_dir.mkdir(mode=0o700)
                (staging_dir / 'pid').write_text(f'{os.getpid()}\n')
            elif pre_create_staging == 'orphaned_backup':
                staging_dir.mkdir(mode=0o700)
                (staging_dir / 'mita.old').write_text('backup\n')
            if remove_binary:
                binary.unlink()

            executable(commands / 'uname', 'case "$1" in -s) echo Linux;; -m) echo x86_64;; esac')
            executable(commands / 'id', '[[ $1 == -u ]] && echo 0')
            executable(commands / 'sleep', ':')
            executable(commands / 'restorecon', f'exit {restorecon_exit}')
            if busybox_tools:
                executable(commands / 'sort', '''
for a in "$@"; do
  if [[ $a == *V* && $a == -* ]]; then
    echo "sort: unrecognized option: V" >&2
    exit 1
  fi
done
exec /usr/bin/sort "$@"
''')
                executable(commands / 'tar', '''
for a in "$@"; do
  if [[ $a == *O* && $a == -* ]]; then
    echo "tar: unrecognized option: O" >&2
    exit 1
  fi
done
exec /usr/bin/tar "$@"
''')
            executable(commands / 'curl', f'''
is_head=0
out=""
url=""
while (( $# )); do
  case "$1" in
    -w) is_head=1; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\\n' "$url" >> "$EVENTS"
if [[ $is_head == 1 ]]; then
  printf 'https://github.com/enfein/mieru/releases/tag/{latest_tag}'
  exit 0
fi
case "$url" in
  *.sha256.txt) cp "$CHECKSUM" "$out" ;;
  *.tar.gz) cp "$RELEASE" "$out" ;;
  *) exit 1 ;;
esac
''')
            service = f'''
case "$*" in
  'is-active --quiet mita.service'|'mita status')
    if [[ $MODE == stopped ]]; then exit 1; fi
    if [[ $MODE == service_dead_after_restart ]] && "$BINARY" version 2>&1 | grep -q '{release_version}'; then exit 1; fi
    exit 0 ;;
  'restart mita.service'|'mita restart')
    version=$("$BINARY" version 2>&1)
    printf 'restart:%s:%s\\n' "${{0##*/}}" "${{version##* }}" >> "$EVENTS"
    if [[ $MODE == interrupted && $version == *{release_version} ]]; then kill -TERM "$UPDATE_PID"; exit 143; fi
    if [[ $MODE == restart_failed && $version == *{release_version} ]]; then exit 1; fi
    echo RUNNING > "$PROXY_STATE" ;;
  'reset-failed mita.service') exit 0 ;;
  *) exit 1 ;;
esac
'''
            for manager in ('systemctl', 'rc-service'):
                executable(commands / manager, service)

            env = {
                **os.environ, 'PATH': f'{commands}:{os.environ["PATH"]}',
                'MODE': mode, 'EVENTS': str(events), 'BINARY': str(binary),
                'PROXY_STATE': str(proxy_state),
                'CHECKSUM': str(checksum), 'RELEASE': str(release),
                'MIERU_VERSION': version, 'MIERU_DRY_RUN': '0',
                'MIERU_STATE_DIR': str(state), 'MIERU_CLIENT_FILE': str(root / 'client.txt'),
            }
            result = subprocess.run(
                ['bash', '-c', 'export UPDATE_PID=$$; exec bash "$@"', 'update-test',
                 script, 'update', *args],
                env=env, capture_output=True, text=True, timeout=12,
            )
            for path, data in config_files.items():
                self.assertEqual(data, path.read_bytes())
                self.assertEqual(0o600, path.stat().st_mode & 0o777)
            actual = None
            if binary.exists():
                actual = subprocess.check_output(
                    [binary, 'version'], env=env, stderr=subprocess.STDOUT, text=True,
                ).split()[-1]
            if mode == 'idle':
                self.assertEqual('IDLE', proxy_state.read_text().strip())
            if pre_create_staging == 'live':
                self.assertTrue(staging_dir.exists())
            elif pre_create_staging != 'orphaned_backup':
                self.assertFalse(staging_dir.exists())
            return result, actual, events.read_text().splitlines()

    def test_updates_active_systemd_and_openrc(self):
        for os_id, manager in [('debian', 'systemctl'), ('alpine', 'rc-service')]:
            with self.subTest(os_id=os_id):
                result, version, events = self.run_update(os_id=os_id)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual('3.40.0', version)
                self.assertEqual(3, len(events))
                self.assertEqual(f'restart:{manager}:3.40.0', events[-1])

    def test_alpine_busybox_without_gnu_sort_v_or_tar_o(self):
        result, version, events = self.run_update(os_id='alpine', installed='3.39.0', busybox_tools=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('', result.stderr)
        self.assertEqual('3.40.0', version)
        self.assertEqual('restart:rc-service:3.40.0', events[-1])

        result, version, events = self.run_update(os_id='alpine', installed='3.41.0', busybox_tools=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('', result.stderr)
        self.assertEqual('3.41.0', version)
        self.assertEqual([], events)

    def test_leaves_stopped_service_stopped(self):
        result, version, events = self.run_update(mode='stopped')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('3.40.0', version)
        self.assertEqual(2, len(events))

    def test_keeps_idle_proxy_paused_without_restarting(self):
        result, version, events = self.run_update(mode='idle')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('3.40.0', version)
        self.assertEqual(2, len(events))
        self.assertIn('IDLE', result.stdout)

    def test_checksum_mismatch_keeps_installed_binary(self):
        result, version, events = self.run_update(mode='bad_digest')
        self.assertNotEqual(0, result.returncode)
        self.assertEqual('3.39.0', version)
        self.assertEqual(2, len(events))

    def test_startup_failure_or_interruption_restores_binary(self):
        for mode in ('unhealthy', 'restart_failed', 'interrupted', 'service_dead_after_restart'):
            with self.subTest(mode=mode):
                result, version, events = self.run_update(mode=mode)
                self.assertNotEqual(0, result.returncode)
                if mode == 'interrupted':
                    self.assertEqual(143, result.returncode)
                self.assertEqual('3.39.0', version)
                self.assertEqual(
                    ['restart:systemctl:3.40.0', 'restart:systemctl:3.39.0'], events[-2:],
                )

    def test_same_or_newer_version_and_dry_run_skip_download(self):
        for kwargs in ({'installed': '3.40.0'}, {'installed': '3.41.0'}, {'args': ('--dry-run',)}):
            with self.subTest(kwargs=kwargs):
                result, version, events = self.run_update(**kwargs)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(kwargs.get('installed', '3.39.0'), version)
                self.assertEqual([], events)

    def test_version_flag_v_prefix_and_explicit_downgrade(self):
        for kwargs in (
            {'args': ('--version', 'v3.40.0')},
            {'version': 'v3.40.0'},
            {'installed': '3.41.0', 'args': ('--version', '3.40.0')},
        ):
            with self.subTest(kwargs=kwargs):
                result, version, events = self.run_update(**kwargs)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual('3.40.0', version)
                self.assertEqual(3, len(events))

    def test_version_latest_resolves_redirect_and_refuses_downgrade(self):
        result, version, events = self.run_update(
            installed='3.39.0', args=('--version', 'latest'), latest_tag='v3.40.0',
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('3.40.0', version)
        self.assertEqual(4, len(events))
        self.assertTrue(events[0].endswith('/releases/latest'))

        result, version, events = self.run_update(
            installed='3.41.0', args=('--version', 'latest'), latest_tag='v3.40.0',
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('3.41.0', version)
        self.assertEqual(1, len(events))

        result, version, events = self.run_update(
            installed='3.39.0', args=('--version', 'latest', '--dry-run'),
        )
        self.assertNotEqual(0, result.returncode)
        self.assertEqual('3.39.0', version)
        self.assertEqual([], events)

    def test_update_rejects_invalid_options_and_versions(self):
        for args in (('--port', '9000'), ('--version', 'bad'), ('--version',)):
            with self.subTest(args=args):
                result, version, events = self.run_update(args=args)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual('3.39.0', version)
                self.assertEqual([], events)

    def test_stale_lock_recovery_live_lock_and_orphaned_backup(self):
        result, version, events = self.run_update(pre_create_staging='stale')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('3.40.0', version)
        self.assertEqual(3, len(events))

        result, version, events = self.run_update(pre_create_staging='live')
        self.assertNotEqual(0, result.returncode)
        self.assertEqual('3.39.0', version)
        self.assertEqual([], events)

        result, version, events = self.run_update(
            pre_create_staging='orphaned_backup', remove_binary=True,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn('mita.old', result.stderr)
        self.assertEqual([], events)

    def test_restorecon_failure_crlf_checksum_and_dot_slash_tarball(self):
        result, version, events = self.run_update(
            restorecon_exit=1,
            tar_arcname='./mita',
            uppercase_crlf_checksum=True,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('3.40.0', version)
        self.assertEqual(3, len(events))

    def test_symlink_in_tarball_is_rejected(self):
        result, version, events = self.run_update(symlink_in_tar=True)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual('3.39.0', version)
        self.assertEqual(2, len(events))


class TestMieruInstallAndHelp(unittest.TestCase):
    def test_dry_run_install_generates_strong_password_and_country_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            dry_dir = Path(directory) / 'dry'
            env = {
                **os.environ,
                'MIERU_DRY_RUN': '1',
                'MIERU_DRYRUN_DIR': str(dry_dir),
            }
            result = subprocess.run(
                ['bash', str(SCRIPT), 'install', '--no-ask-port', '--country', 'hk', '--version', 'v3.40.0'],
                env=env, capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            cfg = json.loads((dry_dir / 'mita-plain.json').read_text())
            password = cfg['users'][0]['password']
            self.assertRegex(password, r'^[A-Za-z0-9]{20}$')
            client_text = (dry_dir / 'mieru-client.txt').read_text()
            self.assertIn(f'password={password}', client_text)
            self.assertIn('HK', client_text)
            self.assertIn('🇭🇰-mieru-01', client_text)

    def test_piped_help_and_update_help_succeed(self):
        script_bytes = SCRIPT.read_bytes()
        for args in (['help'], ['update', '--help']):
            with self.subTest(args=args):
                result = subprocess.run(
                    ['bash', '-s', '--', *args],
                    input=script_bytes, capture_output=True, timeout=10,
                )
                self.assertEqual(0, result.returncode, result.stderr.decode(errors='replace'))
                self.assertIn('mieru-onekey', result.stdout.decode(errors='replace'))

    def test_ask_port_retry_and_explicit_port_precedence(self):
        with tempfile.TemporaryDirectory() as directory:
            dry_dir = Path(directory) / 'dry'
            env = {
                **os.environ,
                'MIERU_DRY_RUN': '1',
                'MIERU_DRYRUN_DIR': str(dry_dir),
                'MIERU_ASK_PORT': '1',
            }
            result = subprocess.run(
                ['bash', str(SCRIPT), 'install'],
                input='80\n22000\n', env=env, capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            cfg = json.loads((dry_dir / 'mita-plain.json').read_text())
            self.assertEqual(22000, cfg['portBindings'][0]['port'])

            result = subprocess.run(
                ['bash', str(SCRIPT), 'install', '--port', '23000'],
                input='9999\n', env=env, capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            cfg = json.loads((dry_dir / 'mita-plain.json').read_text())
            self.assertEqual(23000, cfg['portBindings'][0]['port'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
