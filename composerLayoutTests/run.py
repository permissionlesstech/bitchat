#!/usr/bin/env python3
"""Run the declared composer UI host on an owned, disposable simulator."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import struct
import uuid
import zlib
from runner_support import Interrupted, bounded, install_signal_handlers, manifest, require, save


# This inventory is intentionally independent of source discovery: removing or
# replacing a case must require an explicit coverage update, even for subset runs.
EXPECTED = {
    'testAccessibilityXXXL',
    'testAccessibilityXXXLWide',
    'testActualPhotoPickerGlassLarge',
    'testActualPhotoPickerGlassOrdinary',
    'testActualPhotoPickerMatrixLarge',
    'testActualPhotoPickerMatrixOrdinary',
    'testArabicGlassLarge',
    'testArabicGlassOrdinary',
    'testArabicMatrixLarge',
    'testArabicMatrixOrdinary',
    'testGermanGlassLarge',
    'testGermanGlassOrdinary',
    'testGermanMatrixLarge',
    'testGermanMatrixOrdinary',
    'testGlassAccessibilityXXXL',
    'testGlassAccessibilityXXXLWide',
    'testGlassOrdinary',
    'testGlassOrdinaryNarrow',
    'testHebrewGlassLarge',
    'testHebrewGlassOrdinary',
    'testHebrewMatrixLarge',
    'testHebrewMatrixOrdinary',
    'testMicrophoneGestureUsesSyntheticCapture',
    'testNarrowGlassLargeTextEditing',
    'testNarrowLargeTextEditing',
    'testOrdinary',
    'testOrdinaryNarrow',
}


def declared_inventory(source_text):
    methods = re.findall(r'func (test\w+)\(', source_text)
    discovered = set(methods)
    if len(methods) != len(discovered) or discovered != EXPECTED:
        missing = sorted(EXPECTED - discovered)
        unexpected = sorted(discovered - EXPECTED)
        raise ValueError(f'Composer test definitions differ from required inventory; '
                         f'missing={missing}; unexpected={unexpected}; '
                         f'duplicate_definitions={len(methods) != len(discovered)}')
    return discovered


def seed_photo(simulator, output, source, env):
    def chunk(kind, data):
        return (struct.pack('!I', len(data)) + kind + data
                + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff))
    colors = [(230, 20, 170), (20, 180, 230), (240, 200, 20), (30, 190, 70)]
    pixels = b''.join(b'\x00' + b''.join(bytes(colors[(y >= 32) * 2 + (x >= 48)])
                                       for x in range(96)) for y in range(64))
    png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 96, 64, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))
    photo = output / 'composer-photo.png'
    photo.write_bytes(png)
    require(['xcrun', 'simctl', 'addmedia', simulator, str(photo)], source, env, output, 'seed', 90)


def validate_inventory(summary, raw, expected):
    passed = re.findall(r"Test Case '-\[ComposerLayoutUITests.ComposerLayoutUITests (test\w+)\]' passed", raw)
    valid = (summary.get('totalTestCount') == len(expected)
             and summary.get('passedTests') == len(expected)
             and summary.get('skippedTests') == 0 and len(passed) == len(expected)
             and set(passed) == expected)
    return {'expected': sorted(expected), 'passed': passed, 'valid': valid}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path, help='New output folder outside checkout')
    parser.add_argument('--simulator', help='Template device UUID; only its type/runtime are read. Omit to prepare.')
    parser.add_argument('--packages', type=Path, help='Resolved Xcode package cache')
    parser.add_argument('--composer', type=Path, help='Alternate composer for a baseline control')
    parser.add_argument('--test', action='append', help='Packaged XCTest method; repeat for a subset')
    parser.add_argument('--timeout', type=int, default=600, help='Build command deadline')
    parser.add_argument('--test-timeout', type=int, default=900, help='Test command deadline')
    args = parser.parse_args()
    package = Path(__file__).resolve().parent
    source = package.parent
    try:
        available = declared_inventory((package / 'ComposerLayoutUITests/ComposerLayoutUITests.swift').read_text())
    except ValueError as error:
        parser.error(str(error))
    if args.test and (not set(args.test) <= available or len(args.test) != len(set(args.test))):
        parser.error('--test must name distinct packaged tests')
    output = args.output.resolve()
    if output == source or source in output.parents:
        parser.error('--output must be outside checkout')
    if not 0 < args.timeout <= 600:
        parser.error('--timeout must be between 1 and 600 seconds')
    if not 0 < args.test_timeout <= 900:
        parser.error('--test-timeout must be between 1 and 900 seconds')
    if args.simulator and not args.packages:
        parser.error('--simulator requires --packages')
    output.mkdir(parents=True, exist_ok=False)
    install_signal_handlers()
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_ALLOW_PROTOCOL='file')
    code, reason, device, host, before = 2, 'setup failure', None, source, None
    try:
        if args.composer:
            host = output / 'host'
            shutil.copytree(source, host, ignore=shutil.ignore_patterns('.git', '.build', 'build', '__pycache__'))
            shutil.copyfile(args.composer, host / 'bitchat/Views/ContentComposerView.swift')
        before = manifest(host)
        save(output / 'inputs.json', before)
        if not args.simulator:
            code, reason = 0, 'prepared, not executed'
            return code
        devices = json.loads(require(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], source, env, output, 'devices'))
        matches = [(runtime, item) for runtime, items in devices['devices'].items() for item in items
                   if item['udid'] == args.simulator]
        if len(matches) != 1:
            raise RuntimeError('Template simulator not available')
        runtime, template = matches[0]
        device = require(['xcrun', 'simctl', 'create', 'Composer-' + uuid.uuid4().hex[:8],
                          template['deviceTypeIdentifier'], runtime], source, env, output, 'create').strip()
        save(output / 'owned-device.json', {'udid': device, 'runtime': runtime, 'type': template['deviceTypeIdentifier']})
        common = ['xcodebuild', '-project', 'bitchat.xcodeproj', '-scheme', 'Composer Layout',
                  '-configuration', 'Debug', '-destination', 'platform=iOS Simulator,id=' + device,
                  '-derivedDataPath', str(output / 'derived'), '-clonedSourcePackagesDirPath', str(args.packages.resolve()),
                  '-disableAutomaticPackageResolution', '-skipPackageUpdates', '-jobs', '2',
                  '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
                  '-maximum-test-execution-time-allowance', '60', 'CODE_SIGNING_ALLOWED=NO']
        code = bounded(common + ['build-for-testing'], host, env, output, 'build', args.timeout)
        if code:
            raise RuntimeError(f'build failed with exit {code}')
        # Verify declared membership and the required guard before booting a host.
        binary = output / 'derived/Build/Products/Debug-iphonesimulator/ComposerLayoutHost.app/ComposerLayoutHost.debug.dylib'
        require(['python3', str(package / 'check_invariants.py'), '--source', str(host),
                 '--host-binary', str(binary)], source, env, output, 'invariants')
        require(['xcrun', 'simctl', 'boot', device], source, env, output, 'boot')
        require(['xcrun', 'simctl', 'bootstatus', device, '-b'], source, env, output, 'bootstatus', 120)
        selected = set(args.test) if args.test else available
        if any(name.startswith('testActualPhotoPicker') for name in selected):
            seed_photo(device, output, source, env)
        filters = ['-only-testing:ComposerLayoutUITests/ComposerLayoutUITests/' + name
                   for name in sorted(selected)] if args.test else [
                       '-only-testing:ComposerLayoutUITests/ComposerLayoutUITests']
        command = common + ['-resultBundlePath', str(output / 'result.xcresult')] + filters + ['test-without-building']
        code = bounded(command, host, env, output, 'run', args.test_timeout)
        reason = 'tests passed' if code == 0 else 'tests failed'
        if code == 0:
            summary = json.loads(require(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path',
                                          str(output / 'result.xcresult')], source, env, output, 'summary', 30))
            save(output / 'summary.json', summary)
            inventory = validate_inventory(summary, (output / 'run.log').read_text(), selected)
            save(output / 'inventory.json', inventory)
            if not inventory['valid']:
                code, reason = 2, 'missing, skipped, duplicate or unexpected tests'
    except (Interrupted, KeyboardInterrupt) as error:
        code, reason = 130, str(error)
    except Exception as error:
        code, reason = 2, f'{type(error).__name__}: {error}'
    finally:
        if device:
            cleanup = {}
            for action in ('shutdown', 'delete'):
                try:
                    cleanup[action] = bounded(['xcrun', 'simctl', action, device], source, env, output, action, 30)
                except Exception as error:
                    cleanup[action] = str(error)
            save(output / 'cleanup.json', cleanup)
            if cleanup.get('delete') != 0:
                code, reason = 2, 'owned simulator cleanup failed'
        if before is not None:
            after = manifest(host)
            save(output / 'after-inputs.json', after)
            if before != after:
                code, reason = 2, 'source input drift'
        save(output / 'result.json', {'exit': code, 'reason': reason, 'executed': bool(args.simulator)})
        (output / 'runner-exit.txt').write_text(str(code) + '\n')
        print(f'Composer: {reason}; exit {code}; evidence: {output}', flush=True)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
