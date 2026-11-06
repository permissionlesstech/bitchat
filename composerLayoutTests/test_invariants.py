"""Negative controls for declaration and artifact checks; no builds or simulators."""
import copy
from pathlib import Path
import tempfile
import plistlib
import shutil
import unittest

import check_invariants as checks


class HostInvariantTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parent.parent
        cls.project = checks.load_project(cls.root)

    def test_current_project(self):
        checks.check_project(self.project, self.root)

    def test_folder_exclusion_does_not_replace_exact_files(self):
        project = copy.deepcopy(self.project)
        for obj in project['objects'].values():
            values = obj.get('membershipExceptions', [])
            if '_ComposerTestHost/BitchatApp.swift' in values:
                obj['membershipExceptions'] = ['_ComposerTestHost']
        with self.assertRaisesRegex(ValueError, 'test-host sources not excluded'):
            checks.check_project(project, self.root)

    def test_new_host_file_requires_shipping_exclusion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in ('bitchat/_ComposerTestHost', 'bitchatTests/ComposerSupport',
                             'bitchatTests/ComposerMacTests'):
                shutil.copytree(self.root / relative, root / relative)
            checks.check_project(self.project, root)
            (root / 'bitchat/_ComposerTestHost/NewFixture.swift').write_text('// Future host source\n')
            with self.assertRaisesRegex(ValueError, 'test-host sources not excluded: .*NewFixture.swift'):
                checks.check_project(self.project, root)

    def test_missing_guard_membership_is_rejected(self):
        project = copy.deepcopy(self.project)
        refs = {key for key, obj in project['objects'].items()
                if obj.get('path') == 'composerLayoutTests/NetworkIsolation.c'}
        builds = {key for key, obj in project['objects'].items() if obj.get('fileRef') in refs}
        for obj in project['objects'].values():
            if obj.get('isa') == 'PBXSourcesBuildPhase':
                obj['files'] = [item for item in obj.get('files', []) if item not in builds]
        with self.assertRaisesRegex(ValueError, 'required network guard missing'):
            checks.check_project(project, self.root)

    def test_guard_bytes_required(self):
        valid = b'\0'.join(checks.GUARD_MARKERS)
        checks.check_host_bytes(valid)
        for marker in checks.GUARD_MARKERS:
            with self.subTest(marker=marker):
                with self.assertRaisesRegex(ValueError, 'Built host missing guard marker'):
                    checks.check_host_bytes(valid.replace(marker, b''))

    def test_shipping_artifacts_reject_host_content(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'artifact'
            path.write_bytes(b'production')
            checks.check_shipping_binary(path)
            for marker in checks.HOST_MARKERS:
                path.write_bytes(b'production\0' + marker)
                with self.subTest(marker=marker):
                    with self.assertRaisesRegex(ValueError, 'Shipping binary contains'):
                        checks.check_shipping_binary(path)
            path.write_text('/source/bitchat/BitchatApp.swift\n')
            checks.check_shipping_sources(path)
            path.write_text('/source/bitchat/_ComposerTestHost/BitchatApp.swift\n')
            with self.assertRaisesRegex(ValueError, 'Shipping source list contains'):
                checks.check_shipping_sources(path)
            path.write_text('')
            with self.assertRaisesRegex(ValueError, 'source list is empty'):
                checks.check_shipping_sources(path)

    def test_shipping_derived_requires_real_inventory_and_rejects_contamination(self):
        with tempfile.TemporaryDirectory() as folder:
            derived = Path(folder)
            with self.assertRaisesRegex(ValueError, 'no Swift compiler source lists'):
                checks.check_shipping_derived(derived)
            sources = derived / 'app.SwiftFileList'
            sources.write_text('/source/bitchat/BitchatApp.swift\n')
            with self.assertRaisesRegex(ValueError, 'no Release bitchat.app'):
                checks.check_shipping_derived(derived)
            app = derived / 'Build/Products/Release-iphonesimulator/bitchat.app'
            app.mkdir(parents=True)
            with (app / 'Info.plist').open('wb') as stream:
                plistlib.dump({'CFBundleExecutable': 'bitchat'}, stream)
            (app / 'bitchat').write_bytes(b'production binary')
            checks.check_shipping_derived(derived)
            (app / 'bitchat').write_bytes(b'ComposerLayoutFixture')
            with self.assertRaisesRegex(ValueError, 'Shipping binary contains'):
                checks.check_shipping_derived(derived)

    def test_package_mode_mismatch_rejected(self):
        description = {'targets': [
            {'name': 'bitchat', 'sources': ['BitchatApp.swift']},
            {'name': 'bitchatTests', 'sources': ['OtherTests.swift']} ]}
        checks.check_package_description(description, host=False)
        with self.assertRaisesRegex(ValueError, 'production startup membership incorrect'):
            checks.check_package_description(description, host=True)
        description['targets'][0]['sources'] = ['_ComposerTestHost/BitchatApp.swift',
                                               '_ComposerTestHost/FrameProbes.swift']
        description['targets'][1]['sources'] = ['ComposerSupport/Models.swift',
                                               'ComposerMacTests/MacButtonTests.swift']
        checks.check_package_description(description, host=True)
        description['targets'][1]['sources'].remove('ComposerMacTests/MacButtonTests.swift')
        with self.assertRaisesRegex(ValueError, 'composer support membership incorrect'):
            checks.check_package_description(description, host=True)


if __name__ == '__main__':
    unittest.main()
