"""Regression policy for the repository's indentation-based workflow style.

This deliberately uses only the stdlib, not a general YAML parser. It supports
block mappings, scalar/list triggers, inline or block runner labels, and folded
job conditions. Shell/Python block scalars are never interpreted as YAML keys.
Maintainer approval remains necessary: PRs can edit this test too.
"""

from pathlib import Path
import os
import subprocess
import tempfile
from unittest.mock import patch
import re
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
KEY = re.compile(r'''^(?:-\s+)?(?P<key>[\w-]+|'[\w-]+'|"[\w-]+"):\s*(?P<value>.*)$''')
BLOCK_SCALAR = re.compile(r"^[|>][+-]?[0-9]?$")
# Recognize hosted image labels explicitly; unknown selections fail closed.
GITHUB_HOSTED_RUNNER = re.compile(
    r'(?:ubuntu-(?:latest|20\.04|22\.04|24\.04)(?:-arm)?'
    r'|windows-(?:latest|2019|2022|2025)|windows-11-arm'
    r'|macos-(?:latest|13|14|15|26)|macos-15-intel|xcode-27)'
)
TRUSTED_TRIGGERS = {'workflow_run', 'workflow_dispatch'}
PUBLIC_GUARD = 'github.event.repository.private == false'
REPOSITORY_GUARD = "github.repository == 'letsopen-ai/tinystats'"
DISPATCH_GUARDS = (
    "github.ref == 'refs/heads/main'",
    "github.event_name == 'workflow_dispatch'",
)
RELEASE_GUARDS = (
    "github.event_name == 'workflow_run'",
    "github.event.workflow_run.head_repository.full_name == github.repository",
    "github.event.workflow_run.head_branch == 'main'",
    "github.event.workflow_run.event == 'push'",
    "github.event.workflow_run.conclusion == 'success'",
)


def workflow_lines(source):
    """Keep indentation, remove blank lines and YAML comments outside quotes."""
    lines = []
    for raw in source.splitlines():
        quote = None
        for index, char in enumerate(raw):
            if char in "\"'" and (index == 0 or raw[index - 1] != "\\"):
                if quote == char:
                    quote = None
                elif quote is None:
                    quote = char
            elif char == "#" and quote is None and (index == 0 or raw[index - 1].isspace()):
                raw = raw[:index]
                break
        if raw.strip():
            lines.append((len(raw) - len(raw.lstrip()), raw.strip()))
    return lines


def mapping_fields(lines, indent):
    """Read direct mapping keys and their indented bodies, not nested keys."""
    fields = {}
    index = 0
    while index < len(lines):
        depth, text = lines[index]
        end = index + 1
        while end < len(lines) and lines[end][0] > depth:
            end += 1
        match = KEY.fullmatch(text)
        if depth == indent and match:
            fields[match['key'].strip("\"'")] = (match['value'], lines[index + 1:end])
        index = end
    return fields


def field_text(field):
    value, body = field
    if BLOCK_SCALAR.fullmatch(value):
        value = ""
    return " ".join([value] + [text for _, text in body]).strip()


def step_mappings(lines):
    """Read each block-style step, including steps that start with a name."""
    if not lines:
        return
    indent = lines[0][0]
    starts = [index for index, (depth, text) in enumerate(lines)
              if depth == indent and text.startswith('- ')]
    for start, end in zip(starts, starts[1:] + [len(lines)]):
        item = [(indent + 2, lines[start][1][2:])] + lines[start + 1:end]
        yield mapping_fields(item, indent + 2)


def runner_labels(field):
    """Read literal labels; expressions and group mappings are unsupported."""
    value, body = field
    if body:
        if value or any(not text.startswith('- ') for _, text in body):
            return []
        labels = [text[2:].strip() for _, text in body]
    elif value.startswith('[') and value.endswith(']'):
        labels = [label.strip() for label in value[1:-1].split(',')]
    else:
        labels = [value]
    return [label.strip("\"'") for label in labels]


def is_github_hosted_runner(field):
    """Accept only literal hosted labels, never expressions or group mappings."""
    labels = runner_labels(field)
    return bool(labels) and all(GITHUB_HOSTED_RUNNER.fullmatch(label) for label in labels)


def workflow_security_errors(source):
    lines = workflow_lines(source)
    top = mapping_fields(lines, 0)
    errors = []
    if 'permissions' not in top:
        errors.append('missing top-level permissions')

    value, body = top.get('on', ('', []))
    if value:
        triggers = set(re.findall(r'[\w-]+', value))
    else:
        triggers = set(mapping_fields(body, body[0][0])) if body else set()
    if not triggers:
        errors.append('missing or unsupported workflow triggers')
    if 'pull_request_target' in triggers:
        errors.append('pull_request_target trigger is forbidden')

    _, jobs_body = top.get('jobs', ('', []))
    jobs = mapping_fields(jobs_body, jobs_body[0][0]) if jobs_body else {}
    if not jobs:
        errors.append('missing or unsupported jobs mapping')
    for job, (_, body) in jobs.items():
        fields = mapping_fields(body, body[0][0]) if body else {}
        runner_field = fields.get('runs-on', ('', []))
        labels = runner_labels(runner_field)
        if not is_github_hosted_runner(runner_field):
            errors.append(f'{job}: runner must use an allowed standard GitHub-hosted label')
        macos_job = any(label.startswith(('macos-', 'xcode-')) for label in labels)
        environment, environment_body = fields.get('environment', ('', []))
        if environment_body:
            environment_fields = mapping_fields(environment_body, environment_body[0][0])
            environment = field_text(environment_fields.get('name', ('', [])))
        production = environment.strip("\"'") == 'production'
        native_untrusted = (macos_job and bool(triggers & {'push', 'pull_request'})
                            and triggers <= {'push', 'pull_request', 'workflow_dispatch'})
        trusted_job = ((any(label.startswith('xcode-') for label in labels) and not native_untrusted)
                       or 'workflow_run' in triggers or production)
        if native_untrusted:
            if 'environment' in fields:
                errors.append(f'{job}: untrusted native job must not use an environment')
            for permission in (top.get('permissions'), fields.get('permissions')):
                if permission is None:
                    continue
                value, permission_body = permission
                entries = mapping_fields(permission_body, permission_body[0][0]) if permission_body else {}
                if value or {key: field_text(item) for key, item in entries.items()} != {'contents': 'read'}:
                    errors.append(f'{job}: untrusted native job requires contents: read only')
            inherited_env = top.get('env', ('', []))
            secret_scope = ' '.join(text for _, text in body + inherited_env[1]) + inherited_env[0]
            if re.search(r'\bsecrets\s*(?:\.|\[)', secret_scope, re.I):
                errors.append(f'{job}: untrusted native job must not reference secrets')
        if trusted_job and not triggers <= TRUSTED_TRIGGERS:
            errors.append(f'{job}: untrusted release trigger')
        guard = re.sub(r'\s*==\s*', ' == ', field_text(fields.get('if', ('', []))))
        if guard.startswith('${{') and guard.endswith('}}'):
            guard = guard[3:-2].strip()
        if trusted_job or macos_job:
            # Inequality is allowed; bare ! still negates a guard or expression.
            if '||' in guard or re.search(r'!(?!=)|\balways\s*\(', guard):
                errors.append(f'{job}: guard must use conjunctions without negation or always()')
            parts = {part.strip() for part in guard.split('&&')}
            if PUBLIC_GUARD not in parts:
                errors.append(f'{job}: missing public repository guard')
        if trusted_job:
            if REPOSITORY_GUARD not in parts:
                errors.append(f'{job}: missing repository guard')
            if not (all(term in parts for term in DISPATCH_GUARDS)
                    or all(term in parts for term in RELEASE_GUARDS)):
                errors.append(f'{job}: missing trusted main event guards')
            if production and not all(term in parts for term in (REPOSITORY_GUARD, PUBLIC_GUARD) + RELEASE_GUARDS):
                errors.append(f'{job}: production environment requires full release guards')
            if production or 'workflow_run' in triggers or RELEASE_GUARDS[0] in parts:
                if not production:
                    errors.append(f'{job}: missing production environment')
                permissions, permissions_body = fields.get('permissions', ('', []))
                if (permissions or not permissions_body
                        or not mapping_fields(permissions_body, permissions_body[0][0])):
                    errors.append(f'{job}: missing job-level permissions block')
        for step in step_mappings(fields.get('steps', ('', []))[1]):
            action = field_text(step.get('uses', ('', []))).strip("\"'")
            if action.startswith('actions/checkout@'):
                _, with_body = step.get('with', ('', []))
                inputs = mapping_fields(with_body, with_body[0][0]) if with_body else {}
                credentials = field_text(inputs.get('persist-credentials', ('', [])))
                if credentials.strip("\"'") != 'false':
                    errors.append(f'{job}: checkout must set persist-credentials: false')

    scalar_indent = None
    for depth, text in lines:
        if scalar_indent is not None:
            if depth > scalar_indent:
                continue
            scalar_indent = None
        match = KEY.fullmatch(text)
        if not match:
            continue
        value = match['value']
        if BLOCK_SCALAR.fullmatch(value):
            scalar_indent = depth
        if match['key'].strip("\"'") == 'uses':
            action = value.strip("\"'")
            if not action.startswith('./') and not re.fullmatch(r'[^\s@]+@[0-9a-fA-F]{40}', action):
                errors.append(f'external action must use a full commit SHA: {action}')
    return errors


class WorkflowSecurityTests(unittest.TestCase):
    def test_production_release_concurrency_is_job_scoped(self):
        source = (ROOT / '.github/workflows/production-release.yml').read_text()
        top = mapping_fields(workflow_lines(source), 0)
        self.assertNotIn('concurrency', top)
        jobs_body = top['jobs'][1]
        release_body = mapping_fields(jobs_body, jobs_body[0][0])['release'][1]
        fields = mapping_fields(release_body, release_body[0][0])
        concurrency_body = fields['concurrency'][1]
        concurrency = mapping_fields(concurrency_body, concurrency_body[0][0])
        self.assertEqual(field_text(concurrency['group']), 'production-release')
        self.assertEqual(field_text(concurrency['cancel-in-progress']), 'false')

    def test_production_hosted_contract(self):
        source = (ROOT / '.github/workflows/production-release.yml').read_text()
        top = mapping_fields(workflow_lines(source), 0)
        jobs_body = top['jobs'][1]
        body = mapping_fields(jobs_body, jobs_body[0][0])['release'][1]
        fields = mapping_fields(body, body[0][0])
        self.assertEqual(field_text(fields['runs-on']), 'xcode-27')
        self.assertEqual(field_text(fields['environment']), 'production')
        self.assertEqual(int(field_text(fields['timeout-minutes'])), 180)
        self.assertEqual(workflow_security_errors(source), [])
        for term in (REPOSITORY_GUARD, PUBLIC_GUARD) + RELEASE_GUARDS:
            self.assertTrue(workflow_security_errors(source.replace(term, 'true')))
        permissions = fields['permissions'][1]
        self.assertEqual({key: field_text(value) for key, value in mapping_fields(permissions, permissions[0][0]).items()},
                         {'contents': 'write', 'actions': 'read'})
        steps = list(step_mappings(fields['steps'][1]))
        toolchain = next(step for step in steps if 'scripts/hosted_release_toolchain.py' in field_text(step.get('run', ('', []))))
        self.assertEqual(int(field_text(toolchain['timeout-minutes'])), 20)
        cleanup = [step for step in steps if field_text(step.get('name', ('', []))) == 'Clean up signing material']
        self.assertEqual(len(cleanup), 1)
        self.assertEqual(field_text(cleanup[0]['if']), 'always()')
        for forbidden in ('/Users/', 'release-runner', 'Library/Caches/MacCIReleaseSecrets', 'mac-mini', 'letsopen-org'):
            self.assertNotIn(forbidden, source)
        self.assertLess(source.index('scripts/hosted_release_toolchain.py'), source.index('scripts/verify-local.sh'))
        self.assertLess(source.index('scripts/verify-local.sh'), source.index('secrets.MACOS_CERTIFICATE'))
        gate = next(step for step in steps if 'scripts/verify-local.sh' in field_text(step.get('run', ('', []))))
        self.assertEqual(field_text(gate['if']), "steps.eligibility.outputs.release == 'true'")
        self.assertNotIn('continue-on-error', gate)
        self.assertNotIn('continue-on-error', fields)
        self.assertNotIn('local_release_validation.py check', source)
        self.assertIn('DEVELOPER_DIR: /Applications/Xcode_27.1.app/Contents/Developer', source)
        checkout = next(step for step in steps if 'uses' in step)
        inputs = checkout['with'][1]
        inputs = mapping_fields(inputs, inputs[0][0])
        self.assertEqual(field_text(inputs['fetch-depth']), '0')
        self.assertEqual(field_text(inputs['ref']), '${{ github.event.workflow_run.head_sha }}')

    def test_always_cleanup_detaches_and_deletes_even_after_failure(self):
        source = (ROOT / '.github/workflows/production-release.yml').read_text()
        # Exercise the actual independent workflow script without a real keychain.
        cleanup = textwrap.dedent(source.split('        shell: python3 {0}\n        run: |\n', 1)[1])
        for fail_detach, missing in ((False, False), (True, False), (False, True)):
            with self.subTest(fail_detach=fail_detach, missing=missing), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / 'tinystats-signing'; root.mkdir(mode=0o700)
                (root / 'AuthKey.p8').write_text('fixture')
                keychain = root / 'release-signing.keychain-db'
                calls = []
                def security(args, **kwargs):
                    calls.append(args)
                    command = args[1]
                    if command == 'list-keychains' and '-s' not in args:
                        return subprocess.CompletedProcess(args, 0, '"' + str(keychain) + '"\n"/fixture/other.keychain-db"\n', '')
                    if command == 'list-keychains' and fail_detach:
                        return subprocess.CompletedProcess(args, 1, '', 'fixture failure')
                    return subprocess.CompletedProcess(args, int(command == 'delete-keychain' and missing), '', 'The specified keychain could not be found.')
                with patch.dict(os.environ, {'RUNNER_TEMP': directory}), patch('subprocess.run', side_effect=security):
                    if fail_detach:
                        with self.assertRaises(subprocess.CalledProcessError): exec(cleanup, {})
                    else: exec(cleanup, {})
                self.assertFalse(root.exists())
                self.assertEqual(calls[-1], ['/usr/bin/security', 'delete-keychain', str(keychain)])
                self.assertEqual(calls[1], ['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', '/fixture/other.keychain-db'])

    def test_hosted_smoke_is_secret_free_and_public_main_only(self):
        source = (ROOT / '.github/workflows/hosted-release-smoke.yml').read_text()
        self.assertEqual(workflow_security_errors(source), [])
        self.assertIn('name: Hosted release toolchain smoke', source)
        self.assertNotIn('secrets.', source)
        self.assertNotIn('environment:', source)
        self.assertNotIn('contents: write', source)
        top = mapping_fields(workflow_lines(source), 0)
        jobs_body = top['jobs'][1]
        body = mapping_fields(jobs_body, jobs_body[0][0])['smoke'][1]
        fields = mapping_fields(body, body[0][0])
        toolchain = next(step for step in step_mappings(fields['steps'][1])
                         if 'scripts/hosted_release_toolchain.py' in field_text(step.get('run', ('', []))))
        self.assertEqual(int(field_text(toolchain['timeout-minutes'])), 20)
        self.assertLess(int(field_text(toolchain['timeout-minutes'])), int(field_text(fields['timeout-minutes'])))
        for term in (REPOSITORY_GUARD, PUBLIC_GUARD) + DISPATCH_GUARDS:
            self.assertTrue(workflow_security_errors(source.replace(term, 'true')))

    def test_always_cleanup_skips_empty_search_list_updates(self):
        source = (ROOT / '.github/workflows/production-release.yml').read_text()
        cleanup = textwrap.dedent(source.split('        shell: python3 {0}\n        run: |\n', 1)[1])
        for only_temporary in (False, True):
            with self.subTest(only_temporary=only_temporary), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / 'tinystats-signing'; root.mkdir(mode=0o700)
                keychain = root / 'release-signing.keychain-db'
                def security(args, **kwargs):
                    listing = '"' + str(keychain) + '"\n' if only_temporary else ''
                    return subprocess.CompletedProcess(args, 0, listing, '')
                with patch.dict(os.environ, {'RUNNER_TEMP': directory}), patch('subprocess.run', side_effect=security) as run:
                    exec(cleanup, {})
                self.assertEqual([call.args[0] for call in run.call_args_list], [
                    ['/usr/bin/security', 'list-keychains', '-d', 'user'],
                    ['/usr/bin/security', 'delete-keychain', str(keychain)]])
                self.assertFalse(root.exists())

    def test_repository_workflows(self):
        directory = ROOT / '.github' / 'workflows'
        paths = sorted(path for path in directory.iterdir() if path.suffix in {'.yml', '.yaml'})
        self.assertTrue(paths, 'No workflows found')
        for path in paths:
            with self.subTest(workflow=path.name):
                self.assertEqual(workflow_security_errors(path.read_text()), [])

    def test_bad_pr_workflow_is_flagged(self):
        errors = workflow_security_errors(textwrap.dedent("""\
            on: [pull_request]
            jobs:
              unsafe:
                runs-on: self-hosted
                steps:
                  - uses: actions/checkout@v4
            """))
        for message in ('top-level permissions', 'allowed standard GitHub-hosted label', 'full commit SHA'):
            with self.subTest(message=message):
                self.assertTrue(any(message in error for error in errors), errors)

    def test_any_hosted_macos_job_requires_public_guard(self):
        for label in ('macos-26', 'macos-latest', 'macos-15-intel', 'xcode-27', 'xcode-28'):
            for runner in (label, f'"{label}"', f'[{label}]', f'\n      - {label}'):
                with self.subTest(runner=runner):
                    source = 'on: push\npermissions:\n  contents: read\njobs:\n  build:\n    runs-on: ' + runner + '\n'
                    self.assertIn('build: missing public repository guard', workflow_security_errors(source))
                    guarded = source + '    if: github.event.repository.private == false\n'
                    self.assertNotIn('build: missing public repository guard', workflow_security_errors(guarded))

    def test_production_environment_requires_full_release_guards_on_any_runner(self):
        for environment in ('production', '"production"', '\n      name: production'):
            source = ('on: push\npermissions:\n  contents: read\njobs:\n  unsafe:\n'
                      '    runs-on: ubuntu-latest\n    environment: ' + environment + '\n')
            with self.subTest(environment=environment):
                self.assertIn('unsafe: production environment requires full release guards',
                              workflow_security_errors(source))
        source = self.trusted_dispatch().replace('- xcode-27', '- ubuntu-latest')
        source = source.replace('    steps:', '    environment: production\n    steps:')
        self.assertIn('smoke: production environment requires full release guards', workflow_security_errors(source))
        for term in (REPOSITORY_GUARD, PUBLIC_GUARD) + RELEASE_GUARDS:
            with self.subTest(term=term):
                source = self.trusted_release().replace('- xcode-27', '- ubuntu-latest').replace(term, 'true')
                self.assertIn('smoke: production environment requires full release guards', workflow_security_errors(source))

    def trusted_dispatch(self):
        return textwrap.dedent("""\
            on:
              workflow_dispatch:
            permissions:
              contents: read
            jobs:
              smoke:
                if: >-
                  github.repository == 'letsopen-ai/tinystats' &&
                  github.event.repository.private == false &&
                  github.event_name == 'workflow_dispatch' &&
                  github.ref == 'refs/heads/main'
                runs-on:
                  - xcode-27
                steps:
                  - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # pinned
                    with:
                      persist-credentials: false
                  - uses: ./local-action
                  - run: |
                      uses: this-is-script-text
            """)

    def test_trusted_dispatch_and_script_scalar(self):
        self.assertEqual(workflow_security_errors(self.trusted_dispatch()), [])

    def with_runner(self, runner):
        source = self.trusted_dispatch()
        start = source.index('    runs-on:')
        end = source.index('    steps:')
        return source[:start] + '    runs-on: ' + runner + '\n' + source[end:]

    def test_known_github_hosted_runners(self):
        for label in ('ubuntu-latest', 'ubuntu-22.04', 'ubuntu-24.04-arm',
                      'windows-latest', 'windows-2022', 'windows-2025',
                      'macos-latest', 'macos-14', 'macos-15', 'macos-26',
                      'macos-15-intel'):
            for runner in (label, f'"{label}"', f'[{label}]', f'\n      - {label}'):
                with self.subTest(runner=runner):
                    source = self.with_runner(runner).replace('workflow_dispatch:', 'pull_request:')
                    source = source.replace(REPOSITORY_GUARD, 'true')
                    self.assertEqual(workflow_security_errors(source), [])

    def test_unknown_self_hosted_and_paid_runners_are_rejected(self):
        for runner in ('[self-hosted, macOS]', 'self-hosted', 'macos-26-xlarge',
                       'macos-26-large', 'macos-latest-xlarge', '[]',
                       '[macOS, letsopen-org, release]',
                       '\n      - macOS\n      - letsopen-org\n      - release',
                       'letsopen-m4-release', '${{ inputs.runner }}',
                       '[ubuntu-latest, "${{ inputs.runner }}"]',
                       '{group: default}', '{group: default, labels: ubuntu-latest}',
                       '\n      group: default\n      labels: letsopen-org',
                       'ubuntu-custom', 'windows-custom', 'macos-custom', 'macos-999'):
            with self.subTest(runner=runner):
                source = self.with_runner(runner).replace('workflow_dispatch:', 'pull_request:')
                self.assertIn('smoke: runner must use an allowed standard GitHub-hosted label',
                              workflow_security_errors(source))

    def test_expression_wrapped_conjunction_guard(self):
        source = self.trusted_dispatch().replace('      github.repository', '      ${{ github.repository')
        source = source.replace("github.ref == 'refs/heads/main'", "github.ref == 'refs/heads/main' }}")
        self.assertEqual(workflow_security_errors(source), [])

    def test_disjunction_negation_and_always_guards_are_rejected(self):
        for before, after in ((' &&', ' ||'),
                              (REPOSITORY_GUARD, 'always() && ' + REPOSITORY_GUARD),
                              (REPOSITORY_GUARD, 'always() || ' + REPOSITORY_GUARD),
                              (REPOSITORY_GUARD, '!(' + REPOSITORY_GUARD + ')'),
                              (REPOSITORY_GUARD, '!cancelled() && ' + REPOSITORY_GUARD)):
            with self.subTest(after=after):
                source = self.trusted_dispatch().replace(before, after, 1)
                self.assertIn('smoke: guard must use conjunctions without negation or always()',
                              workflow_security_errors(source))

    def test_inequality_guard_is_allowed(self):
        source = self.trusted_dispatch().replace(
            REPOSITORY_GUARD, REPOSITORY_GUARD + " && github.actor != 'untrusted'")
        self.assertEqual(workflow_security_errors(source), [])

    def test_guard_terms_must_be_exact_conjunction_parts(self):
        for term in (REPOSITORY_GUARD, PUBLIC_GUARD) + DISPATCH_GUARDS:
            with self.subTest(term=term):
                source = self.trusted_dispatch().replace(term, f'contains("{term}", "x")')
                self.assertTrue(workflow_security_errors(source))

    def test_each_dispatch_guard_is_required_at_job_level(self):
        for term in (REPOSITORY_GUARD, PUBLIC_GUARD) + DISPATCH_GUARDS:
            with self.subTest(term=term):
                source = self.trusted_dispatch().replace(term, 'true')
                self.assertTrue(workflow_security_errors(source))
        source = self.trusted_dispatch().replace('    if: >-', '    steps:\n      - if: >-')
        self.assertTrue(workflow_security_errors(source))

    def test_untrusted_trigger_forms(self):
        for trigger in ('pull_request_target', 'issue_comment',
                        'pull_request_review', 'pull_request_review_comment', 'issues',
                        'discussion', 'discussion_comment', 'fork', 'watch', 'schedule'):
            for on in (f'on: {trigger}', f'"on": [push, {trigger}]', f"on:\n  {trigger}:"):
                with self.subTest(on=on):
                    source = self.trusted_dispatch().replace('on:\n  workflow_dispatch:', on)
                    self.assertIn('smoke: untrusted release trigger',
                                  workflow_security_errors(source))
        source = self.trusted_dispatch().replace('workflow_dispatch:', 'pull_request_target:')
        source = source.replace('- xcode-27', '- ubuntu-latest')
        self.assertIn('pull_request_target trigger is forbidden', workflow_security_errors(source))

    def test_source_native_gate_is_secret_free_and_required(self):
        source = (ROOT / '.github/workflows/mac-ci-smoke.yml').read_text()
        self.assertEqual(workflow_security_errors(source), [])
        self.assertIn('name: Release source checks', source)
        top = mapping_fields(workflow_lines(source), 0)
        jobs = mapping_fields(top['jobs'][1], top['jobs'][1][0][0])
        body = jobs['native-validation'][1]
        fields = mapping_fields(body, body[0][0])
        self.assertEqual(field_text(fields['runs-on']), 'xcode-27')
        steps = list(step_mappings(fields['steps'][1]))
        gate = next(step for step in steps if 'scripts/verify-local.sh' in field_text(step.get('run', ('', []))))
        self.assertNotIn('if', gate)
        self.assertNotIn('continue-on-error', gate)
        self.assertNotIn('continue-on-error', fields)
        self.assertIn('scripts/hosted_release_toolchain.py', source)
        self.assertIn("python-version: '3.11'", source)
        self.assertNotIn('local_release_validation.py check', source)
        for addition, error in (('    environment: production\n', 'environment'),
                                ('    env:\n      KEY: ${{ secrets.KEY }}\n', 'secrets'),
                                ('    permissions:\n      contents: write\n', 'contents: read only')):
            broken = source.replace('    runs-on: xcode-27\n', addition + '    runs-on: xcode-27\n')
            self.assertTrue(any(error in item for item in workflow_security_errors(broken)))
        self.assertTrue(workflow_security_errors(source.replace(PUBLIC_GUARD, 'true')))

    def trusted_release(self):
        source = self.trusted_dispatch().replace('workflow_dispatch:', 'workflow_run:')
        start = source.index('    if:')
        end = source.index('    runs-on:')
        guard = '    if: >-\n      ' + ' &&\n      '.join((REPOSITORY_GUARD, PUBLIC_GUARD) + RELEASE_GUARDS) + '\n'
        source = source[:start] + guard + source[end:]
        return source.replace('    steps:', '    environment: production\n'
                              '    permissions:\n      contents: write\n      actions: read\n    steps:')

    def test_each_release_guard_is_required(self):
        source = self.trusted_release()
        self.assertEqual(workflow_security_errors(source), [])
        for term in (REPOSITORY_GUARD, PUBLIC_GUARD) + RELEASE_GUARDS:
            with self.subTest(term=term):
                self.assertTrue(workflow_security_errors(source.replace(term, 'true')))

    def test_release_requires_production_environment(self):
        for replacement in ('', '    environment: staging\n',
                            '    env:\n      environment: production\n',
                            '    environment:\n      name: staging\n'):
            with self.subTest(replacement=replacement):
                source = self.trusted_release().replace('    environment: production\n', replacement)
                self.assertIn('smoke: missing production environment', workflow_security_errors(source))
        source = self.trusted_release().replace('environment: production',
                                               'environment:\n      name: production')
        self.assertEqual(workflow_security_errors(source), [])

    def test_release_requires_job_level_permissions_block(self):
        for replacement in ('', '    permissions: {}\n', '    permissions:\n',
                            '    env:\n      permissions: write-all\n'):
            with self.subTest(replacement=replacement):
                source = self.trusted_release().replace(
                    '    permissions:\n      contents: write\n      actions: read\n', replacement)
                self.assertIn('smoke: missing job-level permissions block', workflow_security_errors(source))

    def test_every_checkout_disables_persisted_credentials(self):
        checkout = ('      - name: Another checkout\n'
                    '        uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262\n'
                    '        with:\n          persist-credentials: false\n')
        for fixture in (self.trusted_dispatch(), self.trusted_release()):
            source = fixture + checkout
            self.assertEqual(workflow_security_errors(source), [])
            for credentials in ('persist-credentials: true', 'unrelated-input: false'):
                for occurrence in (0, 1):
                    with self.subTest(credentials=credentials, occurrence=occurrence, fixture=fixture):
                        setting = 'persist-credentials: false'
                        start = source.index(setting)
                        if occurrence == 1:
                            start = source.index(setting, start + len(setting))
                        broken = source[:start] + credentials + source[start + len(setting):]
                        self.assertIn('smoke: checkout must set persist-credentials: false',
                                      workflow_security_errors(broken))

    def test_commented_guards_and_nested_permissions_do_not_count(self):
        source = self.trusted_dispatch().replace(REPOSITORY_GUARD, 'true # ' + REPOSITORY_GUARD)
        self.assertIn('smoke: missing repository guard', workflow_security_errors(source))
        source = self.trusted_dispatch().replace('permissions:\n  contents: read\n', '')
        source = source.replace('    runs-on:', '    permissions:\n      contents: read\n    runs-on:')
        self.assertIn('missing top-level permissions', workflow_security_errors(source))


if __name__ == '__main__':
    unittest.main()
