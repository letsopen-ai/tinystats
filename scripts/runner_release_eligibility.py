"""Validate a workflow-run request and skip versions that already have a tag."""
import json
import os
from pathlib import Path
import re
import subprocess

from actions_release_guard import api, from_environment

ROOT = Path(__file__).resolve().parents[1]


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
        release = api('releases/tags/' + tag)
        if release.get('draft') or release.get('prerelease') or not release.get('assets'):
            raise ValueError('Existing release is incomplete; reconcile before retrying')
        return False
    return True


if __name__ == '__main__':
    run = eligible()
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('release=' + ('true' if run else 'false') + '\n')
    if not run:
        print('Version already tagged; no release or signing requested.')
