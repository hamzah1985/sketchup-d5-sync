import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bogdan_d5_sync'))
from worker_server import write_progress


class ProgressStatusTests(unittest.TestCase):
    def test_locked_status_keeps_previous_value_and_next_update_recovers(self):
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / 'worker.json'
            status = config.with_name('worker.status.json')
            self.assertTrue(write_progress(config, 'ready'))
            warning = io.StringIO()
            with patch.object(Path, 'replace', side_effect=PermissionError(5, 'Access denied')):
                with contextlib.redirect_stderr(warning):
                    self.assertFalse(write_progress(config, 'processing'))
            self.assertIn('deferred', warning.getvalue())
            self.assertEqual(json.loads(status.read_text())['stage'], 'ready')
            self.assertTrue(write_progress(config, 'sent'))
            self.assertEqual(json.loads(status.read_text())['stage'], 'sent')

    def test_unwritable_temporary_file_is_not_a_sync_failure(self):
        with patch.object(Path, 'write_text', side_effect=PermissionError(5, 'Access denied')):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertFalse(write_progress(Path('worker.json'), 'processing'))
