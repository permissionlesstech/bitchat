"""Portable runner contracts: no simulator, Apple build or network required."""
import importlib.util
import io
from contextlib import redirect_stdout
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from runner_support import Interrupted
from runner_support import bounded, require_json
import run


class RunnerContracts(unittest.TestCase):
    def test_json_output_is_separate_from_tool_warnings(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            result = require_json([sys.executable, '-c',
                'import sys,json; print("warning", file=sys.stderr); print(json.dumps(dict(valid=True)))'],
                output, os.environ, output, 'json', 5)
            self.assertEqual(result, {'valid': True})
            self.assertIn('warning', (output / 'json-stderr.log').read_text())

    def test_failed_json_command_prints_stderr_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            printed = io.StringIO()
            with redirect_stdout(printed), self.assertRaises(RuntimeError):
                require_json([sys.executable, '-c',
                    'import sys; print("metadata failure", file=sys.stderr); sys.exit(3)'],
                    output, os.environ, output, 'json-failure', 5)
            self.assertIn('metadata failure', printed.getvalue())

    def test_missing_skipped_duplicate_and_failed_inventory(self):
        raw = "Test Case '-[ComposerLayoutUITests.ComposerLayoutUITests testExample]' passed"
        summary = dict(totalTestCount=1, passedTests=1, skippedTests=0)
        self.assertTrue(run.validate_inventory(summary, raw, {'testExample'})['valid'])
        self.assertFalse(run.validate_inventory({}, raw, {'testExample'})['valid'])
        self.assertFalse(run.validate_inventory(dict(summary, skippedTests=1), raw, {'testExample'})['valid'])
        self.assertFalse(run.validate_inventory(summary, raw + raw, {'testExample'})['valid'])
        self.assertFalse(run.validate_inventory(summary, '', {'testExample'})['valid'])

    def test_definition_inventory_rejects_removed_renamed_added_and_duplicate_cases(self):
        source = '\n'.join(f'func {name}() {{}}' for name in sorted(run.EXPECTED))
        self.assertEqual(run.declared_inventory(source), run.EXPECTED)
        first = sorted(run.EXPECTED)[0]
        variants = {
            'removed': source.replace(f'func {first}() {{}}', ''),
            'renamed_same_count': source.replace(first, 'testUnexpectedReplacement'),
            'added': source + '\nfunc testUnexpectedAdditional() {}',
            'duplicate': source + f'\nfunc {first}() {{}}',
        }
        for label, variant in variants.items():
            with self.subTest(label=label), self.assertRaisesRegex(ValueError, 'required inventory'):
                run.declared_inventory(variant)

    def test_nonzero_command_and_setup_error_are_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            self.assertEqual(bounded([sys.executable, '-c', 'raise SystemExit(65)'], output,
                                    os.environ, output, 'failed', 5), 65)
            with self.assertRaises(FileNotFoundError):
                bounded(['/nonexistent/composer-command'], output, os.environ, output, 'setup', 5)
            self.assertEqual(json.loads((output / 'setup-result.json').read_text())['exit'], 2)

    def test_deadline_kills_command(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            self.assertEqual(bounded([sys.executable, '-c', 'import time; time.sleep(30)'], output,
                                    os.environ, output, 'timeout', .1), 124)

    def test_interrupt_records_failure_and_stops_child(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            script = ("from pathlib import Path; import os,sys; from runner_support import *; "
                      "install_signal_handlers(); o=Path(sys.argv[1]); "
                      "bounded([sys.executable,'-c',\"import os,time; from pathlib import Path; "
                      "Path('child.pid').write_text(str(os.getpid())); time.sleep(30)\"],o,os.environ,o,'child',30)")
            process = subprocess.Popen([sys.executable, '-c', script, str(output)],
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       env=dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parent)))
            try:
                deadline = time.monotonic() + 5
                while not (output / 'child.pid').exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue((output / 'child.pid').exists())
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=10)
                self.assertEqual(json.loads((output / 'child-result.json').read_text())['exit'], 130)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int((output / 'child.pid').read_text()), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_owned_device_deleted_after_build_failure_or_interruption(self):
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'run'
                calls = []
                def require_stub(command, *args):
                    if command[2] == 'list':
                        return json.dumps({'devices': {'runtime': [dict(udid='template', deviceTypeIdentifier='phone')]}})
                    if command[2] == 'create':
                        return 'owned-device'
                    raise AssertionError(command)
                def bounded_stub(command, *args):
                    calls.append(command)
                    if command[0] == 'xcodebuild':
                        if interrupted:
                            raise Interrupted('test interruption')
                        return 65
                    return 0
                with patch.object(sys, 'argv', ['run.py', '--output', str(output), '--simulator', 'template',
                                               '--packages', directory]), \
                     patch.object(run, 'require', side_effect=require_stub), \
                     patch.object(run, 'bounded', side_effect=bounded_stub), \
                     patch.object(run, 'manifest', return_value={'input': 'unchanged'}), \
                     patch.object(run, 'install_signal_handlers'):
                    self.assertNotEqual(run.main(), 0)
                self.assertIn(['xcrun', 'simctl', 'delete', 'owned-device'], calls)
                self.assertNotIn(['xcrun', 'simctl', 'delete', 'template'], calls)
                result = json.loads((output / 'result.json').read_text())
                self.assertEqual(result['exit'], 130 if interrupted else 2)

    def test_configuration_cache_contains_no_binaries(self):
        spec = importlib.util.spec_from_file_location('mac_runner', Path(__file__).with_name('run-macos.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); original = root / 'normal'; original.mkdir()
            (original / 'checkouts').mkdir(); (original / 'checkouts/package').write_text('resolved')
            (original / 'debug').mkdir(); (original / 'debug/bitchat').write_text('ordinary executable')
            module.seed_dependencies(original, root / 'composer')
            self.assertTrue((root / 'composer/checkouts/package').exists())
            self.assertFalse((root / 'composer/debug').exists())
            self.assertEqual((original / 'debug/bitchat').read_text(), 'ordinary executable')


if __name__ == '__main__':
    unittest.main()
