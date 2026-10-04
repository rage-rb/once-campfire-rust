"""Process-tree sampler regressions."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    'sample_process', Path(__file__).with_name('sample_process.py'))
SAMPLE_PROCESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SAMPLE_PROCESS)


class ProcessTreeTest(unittest.TestCase):
    def test_linux_process_tree_includes_nested_descendants(self):
        with tempfile.TemporaryDirectory() as proc:
            for pid, children in [(10, '11 12'), (11, '13'), (12, ''), (13, '')]:
                path = Path(proc, str(pid), 'task', str(pid))
                path.mkdir(parents=True)
                Path(path, 'children').write_text(children)

            self.assertEqual(SAMPLE_PROCESS.linux_process_tree(10, proc), [10, 11, 12, 13])

    @mock.patch.object(SAMPLE_PROCESS, 'process_tree')
    @mock.patch.object(SAMPLE_PROCESS, 'process')
    def test_aggregate_keeps_cpu_from_replaced_workers(self, process, process_tree):
        process_tree.side_effect = [[10, 11], [10, 12]]
        samples = {
            10: [({'cpu_seconds': 5, 'memory_kb': 100, 'memory_kind': 'PSS'}, (10, 1)),
                 ({'cpu_seconds': 6, 'memory_kb': 100, 'memory_kind': 'PSS'}, (10, 1))],
            11: [({'cpu_seconds': 2, 'memory_kb': 200, 'memory_kind': 'PSS'}, (11, 1))],
            12: [({'cpu_seconds': 0.5, 'memory_kb': 300, 'memory_kind': 'PSS'}, (12, 1))],
        }
        process.side_effect = lambda pid: samples[pid].pop(0)
        sampler = SAMPLE_PROCESS.ProcessTreeSampler(10)

        first = sampler.sample()
        second = sampler.sample()

        self.assertEqual(first['cpu_seconds'], 7)
        self.assertEqual(first['memory_kb'], 300)
        self.assertEqual(first['pids'], [10, 11])
        self.assertEqual(second['cpu_seconds'], 8.5)
        self.assertEqual(second['memory_kb'], 400)
        self.assertEqual(second['process_count'], 2)

    @mock.patch.object(SAMPLE_PROCESS, 'process_tree', return_value=[10, 11])
    @mock.patch.object(SAMPLE_PROCESS, 'process')
    def test_missing_root_ends_sampling(self, process, _process_tree):
        process.side_effect = [ProcessLookupError(10),
                               ({'cpu_seconds': 1, 'memory_kb': 1, 'memory_kind': 'PSS'}, (11, 1))]

        with self.assertRaises(ProcessLookupError):
            SAMPLE_PROCESS.ProcessTreeSampler(10).sample()


if __name__ == '__main__':
    unittest.main()
