#!/usr/bin/env python3
"""Build, notarize and publish an immutable universal production GitHub release.

Run only in an owner-only, clean checkout of fresh main after unsigned CI. Never
pass a signing credential to a PR runner. Logs and build output remain local.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REPO = 'niechen/tinystats'


def run(args, capture=False):
    return subprocess.run(list(map(str, args)), cwd=ROOT, text=True, check=True,
                          capture_output=capture)


def api(path):
    return json.loads(run(['gh', 'api', 'repos/' + REPO + '/' + path], True).stdout)


def source_commit():
    if run(['git', 'status', '--porcelain'], True).stdout.strip():
        raise RuntimeError('Production release requires a clean source checkout')
    if run(['git', 'remote', 'get-url', 'origin'], True).stdout.strip() not in (
            'https://github.com/' + REPO + '.git', 'git@github.com:' + REPO + '.git'):
        raise RuntimeError('Unexpected release repository')
    run(['git', 'fetch', 'origin', 'main', '--tags'])
    sha = run(['git', 'rev-parse', 'HEAD'], True).stdout.strip()
    if sha != run(['git', 'rev-parse', 'origin/main'], True).stdout.strip():
        raise RuntimeError('Release source must equal freshly fetched main')
    return sha


def version_metadata():
    version = (ROOT / 'VERSION').read_text().strip()
    info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    if (not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version)
            or info['CFBundleShortVersionString'] != version
            or info['CFBundleIdentifier'] != 'com.niechen.tinystats'):
        raise RuntimeError('Canonical app version or bundle identity mismatch')
    return version, info['CFBundleVersion']


def check_notary(result):
    data = json.loads(result)
    if data.get('status') != 'Accepted' or not data.get('id'):
        raise RuntimeError('Apple notarization did not accept this archive')
    return data['id']


def assert_unpublished(version):
    releases = api('releases?per_page=100')
    if any(r['tag_name'] == 'v' + version for r in releases):
        raise RuntimeError('This version already has a release; never replace published artifacts')
    refs = api('git/matching-refs/tags/v' + version)
    if any(r['ref'] == 'refs/tags/v' + version for r in refs):
        raise RuntimeError('This version already has a tag; reconcile before retrying')


def verify_release_tag(version, sha):
    obj = api('git/ref/tags/v' + version)['object']
    while obj['type'] == 'tag':
        obj = api('git/tags/' + obj['sha'])['object']
    if obj['type'] != 'commit' or obj['sha'] != sha:
        raise RuntimeError('Release tag does not match the verified source commit')


def request_active(deployment_id, sha):
    deployment = api('deployments/' + str(deployment_id))
    states = api('deployments/' + str(deployment_id) + '/statuses')
    if (deployment['sha'] != sha or deployment['environment'] != 'production'
            or deployment['task'] != 'release-signed'
            or not states or states[0]['state'] != 'in_progress'):
        raise RuntimeError('Release request is no longer active')
    release_run = api('actions/runs/' + str(deployment['payload']['release_run_id']))
    if release_run['status'] != 'in_progress':
        raise RuntimeError('Release workflow was cancelled or expired')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deployment-id', type=int, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    if os.getuid() == 0 or os.environ.get('USER') == 'runner':
        raise RuntimeError('Production signing must run in the owner account')
    sha = source_commit()
    version, build = version_metadata()
    assert_unpublished(version)
    request_active(args.deployment_id, sha)
    config = json.loads((Path.home() / 'Library/Application Support/Teleframe/Signing/apple-signing.json').read_text())
    wanted, team = config['developerIDIdentity'], config['team']
    listing = run(['security', 'find-identity', '-v', '-p', 'codesigning'], True).stdout
    matches = [(key, name) for key, name in re.findall(r'([0-9A-Fa-f]{40}) \"(Developer ID Application:[^\"]+)\"', listing)
               if (key == wanted or name == wanted) and name.endswith('(' + team + ')')]
    if not matches:
        raise RuntimeError('Configured Developer ID identity is unavailable')
    identity = matches[0][0]
    # Never export Apple signing into the full test gate or its ad-hoc packages.
    os.environ.pop('TINYSTATS_SIGN_IDENTITY', None)
    run(['scripts/verify-local.sh'])
    os.environ['TINYSTATS_SIGN_IDENTITY'] = identity
    run(['scripts/build-app.sh', '--universal'])
    submission = run(['xcrun', 'notarytool', 'submit', 'build/TinyStats.zip',
                      '--keychain-profile', 'teleframe-notary', '--wait', '--output-format', 'json'], True)
    submission_id = check_notary(submission.stdout)
    app = ROOT / 'build/TinyStats.app'
    run(['xcrun', 'stapler', 'staple', app])
    run(['xcrun', 'stapler', 'validate', app])
    run(['codesign', '--verify', '--deep', '--strict', app])
    authority = run(['codesign', '-d', '-vv', app], True).stderr
    if 'TeamIdentifier=' + team not in authority.splitlines() or 'Authority=Developer ID Application:' not in authority:
        raise RuntimeError('Signed application has the wrong Developer ID team')
    gatekeeper = run(['spctl', '--assess', '--type', 'execute', '-vv', app], True)
    if 'Notarized Developer ID' not in (gatekeeper.stdout + gatekeeper.stderr):
        raise RuntimeError('Gatekeeper did not confirm notarized Developer ID')
    if set(run(['lipo', '-archs', app / 'Contents/MacOS/TinyStats'], True).stdout.split()) != {'arm64', 'x86_64'}:
        raise RuntimeError('Production app is not universal')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (info['CFBundleShortVersionString'], info['CFBundleVersion'], info['CFBundleIdentifier']) != (version, build, 'com.niechen.tinystats'):
        raise RuntimeError('Signed app metadata differs from release source')
    archive = ROOT / 'build' / ('TinyStats-' + version + '-macOS-universal.zip')
    run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', app, archive])
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    manifest = ROOT / 'build/release.json'
    manifest.write_text(json.dumps({'version': version, 'build': build, 'sourceCommit': sha,
        'sha256': digest, 'file': archive.name, 'notarizationSubmission': submission_id,
        'verification': 'Developer ID; Apple notarization accepted; stapled; Gatekeeper accepted; arm64+x86_64'}, indent=2) + '\n')
    sums = ROOT / 'build/SHA256SUMS.txt'
    sums.write_text(digest + '  ' + archive.name + '\n')
    notes = ROOT / 'build/release-notes.md'
    notes.write_text('Universal Mac production build of `' + sha + '`.\n\n'
        'Developer ID signed, Apple notarized and stapled. Extract TinyStats.app and move it to Applications.\n\n'
        'The full local validation gate passed on the signing host. Native macOS 14/15 and Intel runtime, '
        'hardware and UI qualification remain separate; see docs/DISTRIBUTION.md.\n')
    # Last checks immediately before any tag/release mutation.
    if source_commit() != sha:
        raise RuntimeError('Source changed during release')
    request_active(args.deployment_id, sha)
    assert_unpublished(version)
    run(['git', '-c', 'user.name=Mac CI release', '-c', 'user.email=noreply@github.com',
         'tag', '-a', 'v' + version, sha, '-m', 'TinyStats ' + version])
    run(['git', 'push', 'origin', 'refs/tags/v' + version])
    verify_release_tag(version, sha)
    run(['gh', 'release', 'create', 'v' + version, '--repo', REPO, '--verify-tag',
         '--title', 'TinyStats ' + version, '--notes-file', notes, '--draft', archive, sums, manifest])
    # Verify uploaded bytes before the release becomes downloadable as production.
    downloaded = ROOT / 'build/upload-verification'
    downloaded.mkdir()
    run(['gh', 'release', 'download', 'v' + version, '--repo', REPO, '--dir', downloaded])
    for artifact in (archive, sums, manifest):
        if (downloaded / artifact.name).read_bytes() != artifact.read_bytes():
            raise RuntimeError('Uploaded release bytes did not match verified artifacts')
    request_active(args.deployment_id, sha)
    if source_commit() != sha:
        raise RuntimeError('Main changed before publication; draft retained for reconciliation')
    verify_release_tag(version, sha)
    run(['gh', 'release', 'edit', 'v' + version, '--repo', REPO, '--draft=false', '--latest'])
    published = api('releases/tags/v' + version)
    verify_release_tag(version, sha)
    if published['draft'] or published['prerelease']:
        raise RuntimeError('Production release publication was not confirmed')
    print('Signed and notarized TinyStats ' + version + ' published.')


if __name__ == '__main__':
    main()
