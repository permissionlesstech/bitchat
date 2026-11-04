#!/usr/bin/env python3
"""Check declared host membership and optional compiled artifacts, without building."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

GUARD_MARKERS = (b'COMPOSER_TEST_ISOLATION_INSTALL_FAILED',
                 b'COMPOSER_TEST_ISOLATION_VERIFY_FAILED',
                 b'COMPOSER_TEST_ISOLATION_INSTALLED')
HOST_MARKERS = GUARD_MARKERS + (b'composer_test_isolation_status',
                               b'LocalComposerProbeFrames', b'localComposerProbeFrame',
                               b'ComposerLayoutFixture')
SOURCE_MARKERS = ('/_ComposerTestHost/', '/ComposerSupport/', '/ComposerMacTests/',
                  '/composerLayoutTests/')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_project(root):
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-',
                             str(root / 'bitchat.xcodeproj/project.pbxproj')],
                            capture_output=True, text=True, check=True, timeout=15)
    return json.loads(result.stdout)


def check_project(project, root):
    """Check actual file-level membership, not folder-name exclusion assumptions."""
    objects = project['objects']
    targets = {obj['name']: (key, obj) for key, obj in objects.items()
               if obj.get('isa') == 'PBXNativeTarget'}

    def excluded(target_name, folder):
        key, target = targets[target_name]
        groups = [objects[group] for group in target.get('fileSystemSynchronizedGroups', [])
                  if objects[group].get('path') == folder]
        require(len(groups) == 1, target_name + ': expected synchronized ' + folder + ' group')
        return {path for item in groups[0].get('exceptions', [])
                if objects[item].get('target') == key
                for path in objects[item].get('membershipExceptions', [])}

    host_files = {str(path.relative_to(root / 'bitchat'))
                  for path in (root / 'bitchat/_ComposerTestHost').rglob('*.swift')}
    support_files = {str(path.relative_to(root / 'bitchatTests'))
                     for folder in ('ComposerSupport', 'ComposerMacTests')
                     for path in (root / 'bitchatTests' / folder).rglob('*.swift')}
    require(host_files and support_files, 'Composer support files missing')
    for name in ('bitchat_iOS', 'bitchat_macOS'):
        missing = host_files - excluded(name, 'bitchat')
        require(not missing, name + ': test-host sources not excluded: ' + ', '.join(sorted(missing)))
    for name in ('bitchatTests_iOS', 'bitchatTests_macOS'):
        missing = support_files - excluded(name, 'bitchatTests')
        require(not missing, name + ': composer support not excluded: ' + ', '.join(sorted(missing)))
    host_excluded = excluded('ComposerLayoutHost', 'bitchat')
    require('BitchatApp.swift' in host_excluded, 'ComposerLayoutHost: production startup must be excluded')
    require(not host_files.intersection(host_excluded), 'ComposerLayoutHost: inert startup/probes excluded')
    host = targets['ComposerLayoutHost'][1]
    explicit_sources = {objects[objects[item]['fileRef']].get('path')
                        for phase in host['buildPhases']
                        if objects[phase].get('isa') == 'PBXSourcesBuildPhase'
                        for item in objects[phase].get('files', [])}
    require('composerLayoutTests/NetworkIsolation.c' in explicit_sources,
            'ComposerLayoutHost: required network guard missing from sources')
    return {'normal_host_exclusions': sorted(host_files),
            'normal_test_exclusions': sorted(support_files), 'guard_source_member': True}


def check_host_bytes(data):
    for marker in GUARD_MARKERS:
        require(marker in data, 'Built host missing guard marker: ' + marker.decode())


def check_host_binary(path):
    check_host_bytes(path.read_bytes())
    result = subprocess.run(['nm', '-g', str(path)], capture_output=True, text=True,
                            check=True, timeout=30)
    require(re.search(r'\b[Tt] _composer_test_isolation_status\s*$', result.stdout, re.M),
            'Built host missing defined composer_test_isolation_status symbol')
    # The App initializer calls this symbol before constructing its fixture; the
    # function returns 1 only after constructor installation and denial checks.
    return {'path': str(path), 'required_status_symbol_defined': True,
            'guard_markers_present': True}


def check_shipping_binary(path):
    data = path.read_bytes()
    for marker in HOST_MARKERS:
        require(marker not in data, 'Shipping binary contains test-host marker: ' + marker.decode())
    return {'path': str(path), 'test_host_markers_absent': True}


def check_shipping_sources(path):
    text = path.read_text()
    require(bool(text.strip()), 'Shipping source list is empty')
    for marker in SOURCE_MARKERS:
        require(marker not in text, 'Shipping source list contains test-host path: ' + marker)
    return {'path': str(path), 'test_host_paths_absent': True}


def check_shipping_derived(derived):
    """Inspect compiler source lists and every shipping Release app image present."""
    lists = sorted(derived.rglob('*.SwiftFileList'))
    require(bool(lists), 'Shipping derived data contains no Swift compiler source lists')
    sources = [check_shipping_sources(path) for path in lists]
    require(any('/bitchat/' in path.read_text() for path in lists),
            'Shipping derived data contains no app Swift compiler source list')
    apps = sorted(path for path in (derived / 'Build/Products').glob('Release*/bitchat.app')
                  if path.is_dir())
    require(bool(apps), 'Shipping derived data contains no Release bitchat.app')
    binaries = []
    for app in apps:
        macos = (app / 'Contents/Info.plist').is_file()
        info_path = app / ('Contents/Info.plist' if macos else 'Info.plist')
        with info_path.open('rb') as stream:
            executable = plistlib.load(stream)['CFBundleExecutable']
        require(Path(executable).name == executable, 'Unexpected shipping executable path')
        binary = app / ('Contents/MacOS' if macos else '') / executable
        require(binary.is_file(), 'Shipping executable missing: ' + str(binary))
        binaries.append(check_shipping_binary(binary))
        # Release normally has no debug dylib. If enabled, inspect it as well.
        binaries.extend(check_shipping_binary(path) for path in sorted(binary.parent.glob('*.debug.dylib')))
    return {'source_lists': sources, 'binaries': binaries}


def check_package_description(description, host):
    targets = {target['name']: target for target in description['targets']}
    app = set(targets['bitchat']['sources'])
    tests = set(targets['bitchatTests']['sources'])
    require(('BitchatApp.swift' in app) != host, 'SwiftPM production startup membership incorrect')
    require(('_ComposerTestHost/BitchatApp.swift' in app) == host,
            'SwiftPM inert startup membership incorrect')
    require(('_ComposerTestHost/FrameProbes.swift' in app) == host,
            'SwiftPM frame probe membership incorrect')
    for source in ('ComposerSupport/Models.swift', 'ComposerMacTests/MacButtonTests.swift'):
        require((source in tests) == host, 'SwiftPM composer support membership incorrect: ' + source)
    return {'host_configuration': host, 'membership_valid': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--host-binary', type=Path)
    parser.add_argument('--shipping-binary', type=Path, action='append', default=[])
    parser.add_argument('--shipping-sources', type=Path, action='append', default=[])
    parser.add_argument('--shipping-derived', type=Path, action='append', default=[])
    parser.add_argument('--package-description', type=Path)
    parser.add_argument('--package-host', action='store_true')
    args = parser.parse_args()
    report = {}
    try:
        report['declarations'] = check_project(load_project(args.source), args.source)
        if args.host_binary:
            report['host_binary'] = check_host_binary(args.host_binary)
        report['shipping_binaries'] = [check_shipping_binary(p) for p in args.shipping_binary]
        report['shipping_sources'] = [check_shipping_sources(p) for p in args.shipping_sources]
        report['shipping_derived'] = [check_shipping_derived(p) for p in args.shipping_derived]
        if args.package_description:
            report['package'] = check_package_description(json.loads(args.package_description.read_text()),
                                                          args.package_host)
        report['valid'] = True
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        report.update(valid=False, error=str(error))
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report['valid'] else 2


if __name__ == '__main__':
    raise SystemExit(main())
