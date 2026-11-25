import hashlib
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'mieru-onekey.sh'


class TestMieruUpdate(unittest.TestCase):
    def run_update(self, *, os_id='debian', installed='3.39.0', mode='', version='', args=()):
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
    if [[ $MODE == unhealthy && {mita_version} == 3.40.0 ]]; then echo 'proxy unavailable'; exit 1; fi
    printf 'mita server status is "%s"\\n' "$(cat "$PROXY_STATE")" ;;
  *) echo "unexpected mita command: $1" >&2; exit 1 ;;
esac
'''

            executable(binary, fake_mita(installed))
            release_binary = root / 'mita'
            executable(release_binary, fake_mita('3.40.0'))
            release = root / 'release.tar.gz'
            with tarfile.open(release, 'w:gz') as archive:
                archive.add(release_binary, arcname='mita')
            digest = hashlib.sha256(release.read_bytes()).hexdigest() if mode != 'bad_digest' else '0' * 64
            checksum = root / 'checksum.txt'
            checksum.write_text(f'{digest}  release.tar.gz\n')
            events = root / 'events'
            events.touch()

            executable(commands / 'uname', 'case "$1" in -s) echo Linux;; -m) echo x86_64;; esac')
            executable(commands / 'id', '[[ $1 == -u ]] && echo 0')
            executable(commands / 'sleep', ':')
            executable(commands / 'restorecon', ':')
            executable(commands / 'curl', '''
while [[ $1 != -o ]]; do shift; done
printf '%s\n' "$3" >> "$EVENTS"
case "$3" in
  *.sha256.txt) cp "$CHECKSUM" "$2" ;;
  *.tar.gz) cp "$RELEASE" "$2" ;;
  *) exit 1 ;;
esac
''')
            service = '''
case "$*" in
  'is-active --quiet mita.service'|'mita status') [[ $MODE != stopped ]] ;;
  'restart mita.service'|'mita restart')
    version=$("$BINARY" version 2>&1)
    printf 'restart:%s:%s\n' "${0##*/}" "${version##* }" >> "$EVENTS"
    if [[ $MODE == interrupted && $version == *3.40.0 ]]; then kill -TERM "$UPDATE_PID"; exit 143; fi
    if [[ $MODE == restart_failed && $version == *3.40.0 ]]; then exit 1; fi
    echo RUNNING > "$PROXY_STATE" ;;
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
            actual = subprocess.check_output(
                [binary, 'version'], env=env, stderr=subprocess.STDOUT, text=True,
            ).split()[-1]
            if mode == 'idle':
                self.assertEqual('IDLE', proxy_state.read_text().strip())
            return result, actual, events.read_text().splitlines()

    def test_updates_active_systemd_and_openrc(self):
        for os_id, manager in [('debian', 'systemctl'), ('alpine', 'rc-service')]:
            with self.subTest(os_id=os_id):
                result, version, events = self.run_update(os_id=os_id)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual('3.40.0', version)
                self.assertEqual(3, len(events))
                self.assertEqual(f'restart:{manager}:3.40.0', events[-1])

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
        for mode in ('unhealthy', 'restart_failed', 'interrupted'):
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


if __name__ == '__main__':
    unittest.main(verbosity=2)
