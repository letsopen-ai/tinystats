"""Select the pinned hosted Xcode and install/select its Metal component."""
import json
import os
from pathlib import Path
import platform
import re
import subprocess

DEVELOPER_DIR = '/Applications/Xcode_27.1.app/Contents/Developer'


def select(environment):
    if (environment.get('GITHUB_ACTIONS') != 'true'
            or environment.get('RUNNER_ENVIRONMENT') != 'github-hosted'
            or platform.machine() != 'arm64'):
        raise ValueError('Expected an arm64 GitHub-hosted Actions runner')
    if environment.get('DEVELOPER_DIR') != DEVELOPER_DIR:
        raise ValueError('Expected the pinned Xcode 27.1 developer directory')
    version = subprocess.check_output(['xcodebuild', '-version'], text=True).splitlines()
    if version != ['Xcode 27.1', 'Build version 27A9275']:
        raise ValueError('Expected Xcode 27.1 build 27A9275')
    def component():
        return json.loads(subprocess.check_output(
            ['xcodebuild', '-showComponent', 'MetalToolchain', '-json'], text=True))
    info = component()
    if info.get('status') != 'installed':
        subprocess.run(['xcodebuild', '-downloadComponent', 'MetalToolchain'], check=True, timeout=900)
        info = component()
    search, identifier = info.get('toolchainSearchPath'), info.get('toolchainIdentifier')
    if (info.get('status') != 'installed' or not isinstance(search, str)
            or not isinstance(identifier, str) or any(c in search for c in '\r\n\x00')
            or not Path(search).is_absolute() or not Path(search).is_dir()
            or not re.fullmatch(r'[A-Za-z0-9_.-]+', identifier)):
        raise ValueError('Installed Metal toolchain is unavailable or invalid')
    with open(environment['GITHUB_ENV'], 'a') as output:
        output.write('EXTERNAL_TOOLCHAINS_DIR=' + search + '\n')
        output.write('TOOLCHAINS=' + identifier + ' com.apple.dt.toolchain.XcodeDefault\n')


if __name__ == '__main__':
    select(os.environ)
