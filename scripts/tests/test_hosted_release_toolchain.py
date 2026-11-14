import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import hosted_release_toolchain as toolchain


class HostedToolchainTests(unittest.TestCase):
    def test_installed_or_downloaded_component_and_environment_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
                   'DEVELOPER_DIR': toolchain.DEVELOPER_DIR, 'GITHUB_ENV': str(root / 'env')}
            installed = {'status': 'installed', 'toolchainSearchPath': str(root),
                         'toolchainIdentifier': 'com.apple.metal'}
            for download in (False, True):
                outputs = ['Xcode 27.1\nBuild version 27A9275\n']
                if download: outputs.append(json.dumps({'status': 'not installed'}))
                outputs.append(json.dumps(installed))
                with patch.object(toolchain.platform, 'machine', return_value='arm64'), \
                     patch.object(toolchain.subprocess, 'check_output', side_effect=outputs), \
                     patch.object(toolchain.subprocess, 'run') as run:
                    toolchain.select(env)
                    self.assertEqual(run.call_count, int(download))
                    if download:
                        self.assertEqual(run.call_args.args[0], ['xcodebuild', '-downloadComponent', 'MetalToolchain'])
            self.assertIn('TOOLCHAINS=com.apple.metal com.apple.dt.toolchain.XcodeDefault\n', (root/'env').read_text())
            for version, info in [('Xcode 27.2', installed),
                                  ('Xcode 27.1\nBuild version 27A9275', dict(installed, toolchainIdentifier='bad\nVALUE=x')),
                                  ('Xcode 27.1\nBuild version 27A9275', dict(installed, toolchainSearchPath='/missing/toolchain'))]:
                with patch.object(toolchain.platform, 'machine', return_value='arm64'), \
                     patch.object(toolchain.subprocess, 'check_output', side_effect=[version, json.dumps(info)]):
                    with self.assertRaises(ValueError): toolchain.select(env)
            with patch.object(toolchain.platform, 'machine', return_value='x86_64'), self.assertRaises(ValueError):
                toolchain.select(env)


if __name__ == '__main__': unittest.main()
