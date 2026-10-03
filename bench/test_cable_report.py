"""Runner acceptance regressions: failures must not become publishable throughput."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class CableReportTest(unittest.TestCase):
    def report(self, change=None):
        part = dict(attempted=10, posted=10, complete=10, post_failed=0, all_clients={})
        result = dict(clients=100, ready=100, failed=0, subscriptions_per_client=6,
                      connect_secs=1, compressed_clients=0,
                      latency=copy.deepcopy(part), throughput=copy.deepcopy(part))
        if change:
            change(result)
        with tempfile.TemporaryDirectory() as work:
            Path(work, 'cable-check.json').write_text(json.dumps(result))
            Path(work, 'samp-check.jsonl').write_text('')
            Path(work, 'cable-check.err').write_text('PHASE connect 1000\nPHASE done 2000\n')
            return subprocess.run([sys.executable, str(Path(__file__).with_name('cable_report.py')), work, 'check'],
                                  text=True, capture_output=True)

    def test_complete_run_without_resource_samples(self):
        self.assertEqual(self.report().returncode, 0)

    def test_every_client_and_six_subscriptions_required(self):
        for field, value in [('ready', 0), ('ready', 99), ('failed', 1), ('subscriptions_per_client', 5)]:
            with self.subTest(field=field, value=value):
                self.assertNotEqual(self.report(lambda r: r.update({field: value})).returncode, 0)

    def test_http_failures_and_missing_delivery_in_both_phases(self):
        for phase in ['latency', 'throughput']:
            for change in [dict(post_failed=1, posted=9, complete=9), dict(complete=9),
                           dict(attempted=0, posted=0, complete=0)]:
                with self.subTest(phase=phase, change=change):
                    self.assertNotEqual(self.report(lambda r: r[phase].update(change)).returncode, 0)


if __name__ == '__main__':
    unittest.main()
