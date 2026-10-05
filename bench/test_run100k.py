"""Exercise runner startup without a compiler or a live benchmark server."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).parent / 'results/pi-100k-20260928/run100k.sh'


class Run100kTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.work = self.root / 'work'
        self.events = self.root / 'events'
        self.source = self.root / 'loadgen-source'
        result = self.root / 'result.json'
        phase = dict(attempted=1, posted=1, complete=1, post_failed=0, all_clients={})
        result.write_text(json.dumps(dict(clients=5000, ready=5000, failed=0,
                                         subscriptions_per_client=6, connect_secs=1,
                                         compressed_clients=0, latency=phase, throughput=phase)))
        report = self.root / 'bench/cable_report.py'
        report.parent.mkdir()
        report.write_text(Path(__file__).with_name('cable_report.py').read_text())
        self.executable(self.source, '''
printf '%s\n' "loadgen:$1" >> "$EVENTS"
if [ "$1" = "$FAIL_COMMAND" ]; then
  echo "intentional $1 failure" >&2
  exit 9
fi
case "$1" in
  --help) echo 'usage: loadgen' ;;
  login) echo '{"cookie":"session=test"}' ;;
  scrape) echo '{"streams":["RoomMessagesChannel|room","Turbo::StreamsChannel|room","Turbo::StreamsChannel|user"]}' ;;
  cable) cat "$CABLE_RESULT" ;;
  *) exit 10 ;;
esac
''')
        self.executable(self.bin / 'git', 'printf "%s\\n" "$TEST_REPO"\n')
        self.executable(self.bin / 'rustc', 'echo "host: x86_64-unknown-linux-gnu"\n')
        self.executable(self.bin / 'cargo', '''
printf '%s\n' "cargo:$*" >> "$EVENTS"
[ "$FAIL_COMMAND" != build ] || exit 9
while [ "$#" -gt 0 ]; do
  if [ "$1" = --target ]; then target=$2; break; fi
  shift
done
[ -n "${target:-}" ] || exit 11
dest="$CARGO_TARGET_DIR/$target/release"
mkdir -p "$dest"
cp "$LOADGEN_SOURCE" "$dest/loadgen"
''')
        self.executable(self.bin / 'curl', 'echo curl >> "$EVENTS"\n')
        self.executable(self.bin / 'python3', '''
case "$1" in
  */fill.py) echo fill >> "$EVENTS"; exit 0 ;;
  */sample_process.py) exit 0 ;;
esac
exec ''' + shlex.quote(sys.executable) + ' "$@"\n')
        self.env = {
            **os.environ,
            'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
            'TEST_REPO': str(self.root),
            'WORK': str(self.work),
            'BASE': 'http://example.test:4555',
            'PREPARED': '1',
            'SOURCES': '',
            'EVENTS': str(self.events),
            'LOADGEN_SOURCE': str(self.source),
            'CABLE_RESULT': str(result),
            'FAIL_COMMAND': 'login',
        }
        self.env.pop('LOADGEN', None)

    def executable(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/sh\nset -eu\n' + body)
        path.chmod(0o755)

    def run_runner(self, **env):
        return subprocess.run(['bash', str(RUNNER), '-', 'check', '5000'],
                              env={**self.env, **env}, text=True, capture_output=True,
                              timeout=10)

    def log(self):
        return self.events.read_text().splitlines() if self.events.exists() else []

    def test_native_build_ignores_copied_executable_and_cross_target_setting(self):
        self.executable(self.root / 'target/bench/release/loadgen',
                        'echo copied-binary >> "$EVENTS"\nexit 12\n')
        result = self.run_runner(CARGO_BUILD_TARGET='aarch64-apple-darwin')
        self.assertEqual(result.returncode, 9, result.stderr)
        events = self.log()
        self.assertTrue(events[0].startswith('cargo:build --release --locked -q '), events)
        self.assertIn('--target x86_64-unknown-linux-gnu', events[0])
        self.assertEqual(events[1], 'loadgen:--help')
        self.assertNotIn('copied-binary', events)
        self.assertLess(events.index('loadgen:--help'), events.index('fill'))

    def test_prebuilt_override_skips_build(self):
        result = self.run_runner(LOADGEN=str(self.source))
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertEqual(self.log()[0], 'loadgen:--help')
        self.assertFalse(any(event.startswith('cargo:') for event in self.log()))

    def test_failed_build_stops_before_http_or_fixture_setup(self):
        result = self.run_runner(FAIL_COMMAND='build')
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertEqual(len(self.log()), 1)
        self.assertTrue(self.log()[0].startswith('cargo:'))

    def test_incompatible_override_fails_before_http_or_fixture_setup(self):
        invalid = self.root / 'foreign-loadgen'
        invalid.write_bytes(b'\x7fELF\x00incompatible executable\x00')
        invalid.chmod(0o755)
        result = self.run_runner(LOADGEN=str(invalid))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Cannot run LOADGEN=', result.stderr)
        self.assertIn('unset LOADGEN', result.stderr)
        self.assertEqual(self.log(), [])
        self.assertFalse((self.work / 'cookie').exists())

    def test_failed_login_does_not_feed_empty_output_to_json_parser(self):
        result = self.run_runner(LOADGEN=str(self.source))
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertIn('intentional login failure', result.stderr)
        self.assertNotIn('JSONDecodeError', result.stderr)
        self.assertNotIn('loadgen:scrape', self.log())
        self.assertFalse((self.work / 'cookie').exists())

    def test_failed_scrape_does_not_leave_a_reusable_empty_cache(self):
        result = self.run_runner(LOADGEN=str(self.source), FAIL_COMMAND='scrape')
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertIn('loadgen:scrape', self.log())
        self.assertEqual((self.work / 'cookie').read_text().strip(), 'session=test')
        self.assertFalse((self.work / 'scrape.json').exists())

    def test_successful_run_and_cached_preparation(self):
        for _ in range(2):
            result = self.run_runner(LOADGEN=str(self.source), FAIL_COMMAND='none')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('check ready 5000 failed 0', result.stdout)
        events = self.log()
        self.assertEqual(events.count('loadgen:--help'), 2)
        self.assertEqual(events.count('fill'), 1)
        self.assertEqual(events.count('loadgen:login'), 1)
        self.assertEqual(events.count('loadgen:scrape'), 1)
        self.assertEqual(events.count('loadgen:cable'), 2)


if __name__ == '__main__':
    unittest.main()
