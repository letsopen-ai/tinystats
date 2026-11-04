"""Validate a workflow-run request and skip versions that already have a tag."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from actions_release_guard import api, from_environment

ROOT = Path(__file__).resolve().parents[1]


def verify_published(version, tagged_commit, release):
    name = 'TinyStats-' + version + '-macOS-universal.zip'
    required = {name, 'release.json', 'SHA256SUMS.txt'}
    assets = release.get('assets')
    if not isinstance(assets, list) or not required.issubset({asset.get('name') for asset in assets}):
        raise ValueError('Existing release assets are incomplete')
    with tempfile.TemporaryDirectory(prefix='tinystats-release-check-') as directory:
        args = ['gh', 'release', 'download', 'v' + version, '--repo', 'letsopen-ai/tinystats', '--dir', directory]
        for item in sorted(required):
            args += ['--pattern', item]
        subprocess.run(args, check=True, timeout=300)
        root = Path(directory)
        if any((root / item).is_symlink() or not (root / item).is_file() for item in required):
            raise ValueError('Existing release download is incomplete')
        if (root / 'release.json').stat().st_size > 65536 or (root / 'SHA256SUMS.txt').stat().st_size > 65536:
            raise ValueError('Existing release metadata is oversized')
        manifest = json.loads((root / 'release.json').read_text())
        digest = manifest.get('sha256')
        if (manifest.get('version') != version or manifest.get('sourceCommit') != tagged_commit
                or manifest.get('file') != name or not isinstance(digest, str)
                or not re.fullmatch(r'[0-9a-f]{64}', digest)
                or (root / 'SHA256SUMS.txt').read_text() != digest + '  ' + name + '\n'):
            raise ValueError('Existing release metadata does not match its tag')
        archive = root / name
        if archive.stat().st_size > 512 * 1024 * 1024:
            raise ValueError('Existing release archive is oversized')
        value = hashlib.sha256()
        with archive.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                value.update(block)
        if value.hexdigest() != digest:
            raise ValueError('Existing release archive checksum differs')


def eligible():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    commit = (event.get('workflow_run') or {}).get('head_sha')
    from_environment(commit)
    version = (ROOT / 'VERSION').read_text().strip()
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('Invalid canonical release version')
    ref = 'refs/tags/v' + version
    refs = api('git/matching-refs/tags/v' + version)
    if any(item.get('ref') == ref for item in refs):
        tag = 'v' + version
        tagged_version = subprocess.check_output(['git', 'show', tag + ':VERSION'], cwd=ROOT, text=True).strip()
        if tagged_version != version:
            raise ValueError('Existing release tag version mismatch')
        subprocess.run(['git', 'merge-base', '--is-ancestor', tag, commit], cwd=ROOT, check=True)
        tagged_commit = subprocess.check_output(['git', 'rev-list', '-n', '1', tag], cwd=ROOT, text=True).strip()
        if not re.fullmatch(r'[0-9a-f]{40}', tagged_commit):
            raise ValueError('Existing release tag does not resolve to a commit')
        release = api('releases/tags/' + tag)
        if release.get('draft') or release.get('prerelease') or not release.get('assets'):
            raise ValueError('Existing release is incomplete; reconcile before retrying')
        verify_published(version, tagged_commit, release)
        return False
    return True


if __name__ == '__main__':
    run = eligible()
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('release=' + ('true' if run else 'false') + '\n')
    if not run:
        print('Version already tagged; no release or signing requested.')
