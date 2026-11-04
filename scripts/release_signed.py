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
import pwd
import re
import subprocess
import sys
from notary_config import keychain_arguments

ROOT = Path(__file__).resolve().parents[1]
REPO = 'letsopen-ai/tinystats'


def run(args, capture=False):
    return subprocess.run(list(map(str, args)), cwd=ROOT, text=True, check=True,
                          capture_output=capture)


def api(path):
    return json.loads(run(['gh', 'api', 'repos/' + REPO + '/' + path], True).stdout)


def source_commit():
    if run(['git', 'status', '--porcelain'], True).stdout.strip():
        raise RuntimeError('Production release requires a clean source checkout')
    if run(['git', 'remote', 'get-url', 'origin'], True).stdout.strip() not in (
            'https://github.com/' + REPO, 'https://github.com/' + REPO + '.git',
            'git@github.com:' + REPO, 'git@github.com:' + REPO + '.git'):
        raise RuntimeError('Unexpected release repository')
    fetch = ['git']
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        fetch += ['-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential']
    run([*fetch, 'fetch', 'origin', 'main', '--tags'])
    sha = run(['git', 'rev-parse', 'HEAD'], True).stdout.strip()
    if sha != run(['git', 'rev-parse', 'origin/main'], True).stdout.strip():
        raise RuntimeError('Release source must equal freshly fetched main')
    return sha


def verify_ci_validation(sha):
    """Recheck the exact source manifest produced by the full unsigned gate."""
    ci = ROOT / 'build/ci'
    before, after, marker = (ci / 'source-manifest.json', ci / 'source-manifest-after.json', ci / 'LOCAL-PASS.txt')
    if any(p.is_symlink() or not p.is_file() for p in (before, after, marker)):
        raise RuntimeError('Missing completed local validation evidence')
    if not marker.read_text().startswith('Local validation passed for the inputs in source-manifest.json.'):
        raise RuntimeError('Invalid local validation marker')
    manifest = json.loads(before.read_text())
    if manifest != json.loads(after.read_text()) or manifest.get('base_commit') != sha or manifest.get('build_mirror') is not False:
        raise RuntimeError('Validation source does not match the release')
    areas = ['Sources', 'Tests', 'Resources', 'scripts', '.github', 'Package.swift', 'Package.resolved',
             'VERSION', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'AGENTS.md']
    names = run(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', *areas], True).stdout.split('\0')
    inputs = {}
    for name in sorted(set(names)):
        if not name: continue
        path = ROOT / name
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(ROOT.resolve()):
            raise RuntimeError('Invalid validation input')
        inputs[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    if manifest.get('inputs') != inputs:
        raise RuntimeError('Validation inputs changed after testing')



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
    if deployment_id is None:
        from actions_release_guard import from_environment
        from_environment(sha)
        return
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
    authority = parser.add_mutually_exclusive_group(required=True)
    authority.add_argument('--deployment-id', type=int)
    authority.add_argument('--actions-direct', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    if os.getuid() == 0 or os.environ.get('USER') == 'runner':
        raise RuntimeError('Production signing must not run as root or the unsigned runner')
    if args.actions_direct and (os.environ.get('GITHUB_ACTIONS') != 'true' or
                                pwd.getpwuid(os.getuid()).pw_name != 'release-runner'):
        raise RuntimeError('Direct release requires the dedicated Actions runner')
    sha = source_commit()
    version, build = version_metadata()
    assert_unpublished(version)
    request_active(args.deployment_id, sha)
    if args.actions_direct:
        team = os.environ.get('APPLE_TEAM_ID', '')
        wanted = os.environ.get('TINYSTATS_DEVELOPER_ID', '')
        if not re.fullmatch(r'[A-Z0-9]{10}', team) or not re.fullmatch(r'[A-Fa-f0-9]{40}', wanted):
            raise RuntimeError('Invalid Apple team or signing fingerprint')
    else:
        config = json.loads((Path.home() / 'Library/Application Support/Teleframe/Signing/apple-signing.json').read_text())
        wanted, team = config['developerIDIdentity'], config['team']
    listing = run(['security', 'find-identity', '-v', '-p', 'codesigning'], True).stdout
    matches = [(key, name) for key, name in re.findall(r'([0-9A-Fa-f]{40}) \"(Developer ID Application:[^\"]+)\"', listing)
               if (key.upper() == wanted.upper() or name == wanted) and name.endswith('(' + team + ')')]
    if not matches:
        raise RuntimeError('Configured Developer ID identity is unavailable')
    identity = matches[0][0]
    # The direct Actions path runs the full gate before importing credentials.
    os.environ.pop('TINYSTATS_SIGN_IDENTITY', None)
    if args.actions_direct:
        verify_ci_validation(sha)
    else:
        run(['scripts/verify-local.sh'])
    os.environ['TINYSTATS_SIGN_IDENTITY'] = identity
    run(['scripts/build-app.sh', '--universal'])
    submission = run(['xcrun', 'notarytool', 'submit', 'build/TinyStats.zip',
                      '--keychain-profile', os.environ.get('TELEFRAME_NOTARY_PROFILE', 'teleframe-notary'),
                      *keychain_arguments(os.environ), '--wait', '--output-format', 'json'], True)
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
    if args.actions_direct:
        verify_ci_validation(sha)
    if source_commit() != sha:
        raise RuntimeError('Source changed during release')
    request_active(args.deployment_id, sha)
    assert_unpublished(version)
    run(['git', '-c', 'user.name=Mac CI release', '-c', 'user.email=noreply@github.com',
         'tag', '-a', 'v' + version, sha, '-m', 'TinyStats ' + version])
    push = ['git']
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        push += ['-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential']
    run([*push, 'push', 'origin', 'refs/tags/v' + version])
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
