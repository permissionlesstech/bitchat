#!/usr/bin/env python3
"""Run four native composer button cases using the declared inert SwiftPM host."""
import argparse
import json
import os
from pathlib import Path
import re

from runner_support import Interrupted, bounded, install_signal_handlers, manifest, require_json, save
import shutil

EXPECTED = {'testMatrixNarrowButtons', 'testGlassNarrowButtons',
            'testMatrixLargeButtons', 'testGlassLargeButtons'}


def seed_dependencies(original, scratch):
    """Copy resolved inputs, never alternate configuration binaries."""
    scratch.mkdir()
    for name in ('artifacts', 'checkouts', 'repositories', 'workspace-state.json'):
        source = original / name
        if source.is_dir():
            shutil.copytree(source, scratch / name, symlinks=True)
        elif source.is_file():
            shutil.copy2(source, scratch / name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New folder outside the checkout')
    parser.add_argument('--scratch-path', type=Path, help='Existing resolved SwiftPM scratch/cache directory')
    parser.add_argument('--prepare-only', action='store_true', help='Record declared host inputs without building')
    parser.add_argument('--build-timeout', type=int, default=600)
    parser.add_argument('--test-timeout', type=int, default=120)
    args = parser.parse_args()
    package = Path(__file__).resolve().parent
    source = package.parent
    output = args.output.resolve()
    if output == source or source in output.parents:
        parser.error('--output must be outside the checkout')
    if not 0 < args.build_timeout <= 600 or not 0 < args.test_timeout <= 120:
        parser.error('Build/test deadlines must be positive and at most 600/120 seconds')
    if not args.prepare_only and (not args.scratch_path or not args.scratch_path.is_dir()):
        parser.error('Running requires --scratch-path with already resolved dependencies')
    if args.scratch_path:
        dependency_cache = args.scratch_path.resolve()
        scratch = dependency_cache
        if (scratch == source or source in scratch.parents) and scratch != source / '.build':
            parser.error('--scratch-path must be outside the checkout or its existing .build cache')
    output.mkdir(parents=True, exist_ok=False)
    install_signal_handlers()
    before = manifest(source)
    save(output / 'source-inputs.json', before)
    # Package.swift declares the alternate entry point, frame probes and composer
    # test membership. This runner filters four cases without rewriting sources.
    inputs = before
    save(output / 'host-inputs.json', inputs)
    if args.prepare_only:
        save(output / 'result.json', {'prepared': True, 'executed': False})
        print(source)
        return 0

    # Build the alternate configuration in its own output tree. Only resolved
    # package inputs are copied from the ordinary configuration's cache.
    scratch = output / 'scratch'
    code, reason = 2, 'setup failure'
    try:
        seed_dependencies(dependency_cache, scratch)
        code = execute(source, output, scratch, args)
        reason = 'tests passed' if code == 0 else 'build, test or inventory failure'
    except (Interrupted, KeyboardInterrupt) as error:
        code, reason = 130, str(error)
    except Exception as error:
        code, reason = 2, f'{type(error).__name__}: {error}'
    finally:
        after = manifest(source)
        save(output / 'after-source-inputs.json', after)
        unchanged = before == after
        if not unchanged:
            code, reason = 2, 'source input drift'
        save(output / 'result.json', {'exit': code, 'reason': reason, 'executed': True,
                                      'inputs_unchanged': unchanged})
        print(f'Mac composer: {reason}; exit {code}; evidence: {output}', flush=True)
    return code


def execute(source, output, scratch, args):
    # Kernel restrictions apply to this process tree, not the whole machine.
    # Block network and real keychain services. Redirect mutable home/cache state.
    for name in ('home', 'temp', 'cache', 'config', 'security', 'clang-cache', 'swift-cache'):
        (output / name).mkdir()
    quote = lambda value: json.dumps(str(value))
    profile = '\n'.join([
        '(version 1)', '(allow default)', '(deny network*)', '(deny file-write*)',
        '(allow file-write* (literal "/dev/null") (subpath ' + quote(output) + ')',
        ' (subpath ' + quote(scratch) + ') (subpath "/private/tmp") (subpath "/private/var/folders"))',
        '(deny file-read* (subpath ' + quote(Path.home() / 'Library') + '))',
        '(allow file-read* (subpath ' + quote(Path.home() / 'Library/Developer') + '))',
        '(deny mach-lookup (global-name "com.apple.securityd"))',
        '(deny mach-lookup (global-name "com.apple.cfprefsd.agent"))',
    ]) + '\n'
    sandbox = output / 'runtime.sb'
    sandbox.write_text(profile)
    env = dict(os.environ, CFFIXED_USER_HOME=str(output / 'home'), TMPDIR=str(output / 'temp') + '/',
               XDG_CACHE_HOME=str(output / 'cache'), CLANG_MODULE_CACHE_PATH=str(output / 'clang-cache'),
               SWIFTPM_MODULECACHE_OVERRIDE=str(output / 'swift-cache'), GIT_ALLOW_PROTOCOL='file',
               GIT_TERMINAL_PROMPT='0', CI='1', COMPOSER_TEST_HOST='1')
    flags = ['--disable-sandbox', '--skip-update', '--disable-automatic-resolution',
             '--scratch-path', str(scratch), '--cache-path', str(output / 'cache'),
             '--config-path', str(output / 'config'), '--security-path', str(output / 'security'), '--jobs', '2']
    prefix = ['/usr/bin/sandbox-exec', '-f', str(sandbox), 'swift']
    from check_invariants import check_package_description, check_project, load_project
    save(output / 'project-invariants.json', check_project(load_project(source), source))
    for host_mode in (False, True):
        mode_env = dict(env)
        if not host_mode:
            mode_env.pop('COMPOSER_TEST_HOST', None)
        description = require_json(prefix + ['package'] + flags + ['describe', '--type', 'json'],
                                         source, mode_env, output, 'package-host' if host_mode else 'package-normal', 60)
        save(output / ('membership-host.json' if host_mode else 'membership-normal.json'),
             check_package_description(description, host_mode))
    code = bounded(prefix + ['build', '--build-tests'] + flags, source, env, output, 'build', args.build_timeout)
    if code == 0:
        code = bounded(prefix + ['test', '--skip-build', '--filter', 'MacButtonTests'] + flags,
                       source, env, output, 'test', args.test_timeout)
        raw = (output / 'test.log').read_text()
        passed = re.findall(r"Test Case '-\[bitchatTests.MacButtonTests (test\w+)\]' passed", raw)
        valid = (len(passed) == 4 and set(passed) == EXPECTED
                 and not re.search(r"Test Case .* (?:skipped|failed)", raw)
                 and re.search(r'Executed 4 tests, with 0 failures', raw) is not None)
        save(output / 'inventory.json', {'expected': sorted(EXPECTED), 'passed': passed,
                                       'zero_skips_and_exact_inventory': valid})
        if code == 0 and not valid:
            code = 2
    return code


if __name__ == '__main__':
    raise SystemExit(main())
