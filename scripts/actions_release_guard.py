"""Validate a direct GitHub Actions release request against GitHub API facts."""
import json
import os
from pathlib import Path
import re
import subprocess

REPO = 'letsopen-ai/tinystats'


def api(path):
    result = subprocess.run(['gh', 'api', f'repos/{REPO}/{path}'], text=True,
                            capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Could not validate release request with GitHub')
    return json.loads(result.stdout)


def _identifier(value):
    if not isinstance(value, str) or not value.isascii() or not value.isdecimal() or int(value) <= 0:
        raise ValueError('Invalid workflow run identifier')
    return int(value)


def validate(commit, ci_id, release_id):
    """Fail closed if main, triggering CI or the current release run changes."""
    if not isinstance(commit, str) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Invalid release source')
    ci_id, release_id = _identifier(ci_id), _identifier(release_id)
    if ci_id == release_id:
        raise ValueError('CI and release runs must differ')
    main = api('git/ref/heads/main')['object']['sha']
    ci = api('actions/runs/' + str(ci_id))
    release = api('actions/runs/' + str(release_id))
    if main != commit:
        raise ValueError('Release source is no longer main')
    for run, identifier, path in ((ci, ci_id, '.github/workflows/mac-ci-smoke.yml'),
                                  (release, release_id, '.github/workflows/production-release.yml')):
        if (run.get('id') != identifier or run.get('path') != path
                or run.get('head_sha') != commit or run.get('head_branch') != 'main'
                or run.get('repository', {}).get('full_name') != REPO
                or run.get('head_repository', {}).get('full_name') != REPO):
            raise ValueError('Workflow identity or source mismatch')
    if ci.get('event') != 'push' or ci.get('status') != 'completed' or ci.get('conclusion') != 'success':
        raise ValueError('Release requires successful main push CI')
    if release.get('event') != 'workflow_run' or release.get('status') != 'in_progress':
        raise ValueError('Release run is not active')
    return commit


def from_environment(commit):
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('GITHUB_REPOSITORY') != REPO:
        raise ValueError('Expected the designated GitHub Actions repository')
    if os.environ.get('GITHUB_EVENT_NAME') != 'workflow_run':
        raise ValueError('Release must originate from a workflow_run event')
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    trigger = event.get('workflow_run') or {}
    if trigger.get('head_sha') != commit or type(trigger.get('id')) is not int:
        raise ValueError('Trigger source does not match release')
    return validate(commit, str(trigger['id']), os.environ.get('GITHUB_RUN_ID', ''))
