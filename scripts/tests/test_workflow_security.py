"""Regression policy for the repository's indentation-based workflow style.

This deliberately uses only the stdlib, not a general YAML parser. It supports
block mappings, scalar/list triggers, inline or block runner labels, and folded
job conditions. Shell/Python block scalars are never interpreted as YAML keys.
Runner reachability and human approval remain necessary: PRs can edit this test too.
"""

from pathlib import Path
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
    r'|macos-(?:latest|13|14|15|26)(?:-large|-xlarge)?|macos-15-intel)'
)
SELF_HOSTED_TRIGGERS = {'push', 'workflow_run', 'workflow_dispatch'}
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


def is_github_hosted_runner(field):
    """Accept only literal hosted labels, never expressions or group mappings."""
    value, body = field
    if body:
        if value or any(not text.startswith('- ') for _, text in body):
            return False
        labels = [text[2:].strip() for _, text in body]
    elif value.startswith('[') and value.endswith(']'):
        labels = [label.strip() for label in value[1:-1].split(',')]
    else:
        labels = [value]
    return all(GITHUB_HOSTED_RUNNER.fullmatch(label.strip("\"'")) for label in labels)


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
        runner = field_text(runner_field)
        labels = set(re.findall(r'[\w-]+', runner))
        if is_github_hosted_runner(runner_field):
            continue
        if not triggers <= SELF_HOSTED_TRIGGERS:
            errors.append(f'{job}: untrusted trigger with self-hosted runner')
        if 'letsopen-org' not in labels:
            errors.append(f'{job}: self-hosted runner missing letsopen-org label')
        guard = re.sub(r'\s*==\s*', ' == ', field_text(fields.get('if', ('', []))))
        if guard.startswith('${{') and guard.endswith('}}'):
            guard = guard[3:-2].strip()
        if '||' in guard or '!' in guard or re.search(r'\balways\s*\(', guard):
            errors.append(f'{job}: guard must use conjunctions without negation or always()')
        parts = {part.strip() for part in guard.split('&&')}
        if REPOSITORY_GUARD not in parts:
            errors.append(f'{job}: missing repository guard')
        if not (all(term in parts for term in DISPATCH_GUARDS)
                or all(term in parts for term in RELEASE_GUARDS)):
            errors.append(f'{job}: missing trusted main event guards')

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
        for message in ('top-level permissions', 'untrusted trigger', 'letsopen-org',
                        'repository guard', 'trusted main event guards', 'full commit SHA'):
            with self.subTest(message=message):
                self.assertTrue(any(message in error for error in errors), errors)

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
                  github.event_name == 'workflow_dispatch' &&
                  github.ref == 'refs/heads/main'
                runs-on:
                  - self-hosted
                  - letsopen-org
                steps:
                  - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # pinned
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
                      'macos-15-intel', 'macos-26-large', 'macos-latest-xlarge'):
            for runner in (label, f'"{label}"', f'[{label}]', f'\n      - {label}'):
                with self.subTest(runner=runner):
                    source = self.with_runner(runner).replace('workflow_dispatch:', 'pull_request:')
                    source = source.replace(REPOSITORY_GUARD, 'true')
                    self.assertEqual(workflow_security_errors(source), [])

    def test_unknown_runner_forms_are_self_hosted(self):
        for runner in ('[macOS, letsopen-org, release]',
                       '\n      - macOS\n      - letsopen-org\n      - release',
                       'letsopen-m4-release', '${{ inputs.runner }}',
                       '[ubuntu-latest, "${{ inputs.runner }}"]',
                       '{group: default}', '{group: default, labels: ubuntu-latest}',
                       '\n      group: default\n      labels: letsopen-org',
                       'ubuntu-custom', 'windows-custom', 'macos-custom', 'macos-999'):
            with self.subTest(runner=runner):
                source = self.with_runner(runner).replace('workflow_dispatch:', 'pull_request:')
                self.assertIn('smoke: untrusted trigger with self-hosted runner',
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

    def test_guard_terms_must_be_exact_conjunction_parts(self):
        for term in (REPOSITORY_GUARD,) + DISPATCH_GUARDS:
            with self.subTest(term=term):
                source = self.trusted_dispatch().replace(term, f'contains("{term}", "x")')
                self.assertTrue(workflow_security_errors(source))

    def test_each_dispatch_guard_is_required_at_job_level(self):
        for term in (REPOSITORY_GUARD,) + DISPATCH_GUARDS:
            with self.subTest(term=term):
                source = self.trusted_dispatch().replace(term, 'true')
                self.assertTrue(workflow_security_errors(source))
        source = self.trusted_dispatch().replace('    if: >-', '    steps:\n      - if: >-')
        self.assertTrue(workflow_security_errors(source))

    def test_untrusted_trigger_forms(self):
        for trigger in ('pull_request', 'pull_request_target', 'issue_comment',
                        'pull_request_review', 'pull_request_review_comment', 'issues',
                        'discussion', 'discussion_comment', 'fork', 'watch', 'schedule'):
            for on in (f'on: {trigger}', f'"on": [push, {trigger}]', f"on:\n  {trigger}:"):
                with self.subTest(on=on):
                    source = self.trusted_dispatch().replace('on:\n  workflow_dispatch:', on)
                    self.assertIn('smoke: untrusted trigger with self-hosted runner',
                                  workflow_security_errors(source))
        source = self.trusted_dispatch().replace('workflow_dispatch:', 'pull_request_target:')
        source = source.replace('- self-hosted', '- ubuntu-latest')
        self.assertIn('pull_request_target trigger is forbidden', workflow_security_errors(source))

    def test_each_release_guard_is_required(self):
        source = self.trusted_dispatch().replace('workflow_dispatch:', 'workflow_run:')
        start = source.index('    if:')
        end = source.index('    runs-on:')
        guard = '    if: >-\n      ' + ' &&\n      '.join((REPOSITORY_GUARD,) + RELEASE_GUARDS) + '\n'
        source = source[:start] + guard + source[end:]
        self.assertEqual(workflow_security_errors(source), [])
        for term in (REPOSITORY_GUARD,) + RELEASE_GUARDS:
            with self.subTest(term=term):
                self.assertTrue(workflow_security_errors(source.replace(term, 'true')))

    def test_commented_guards_and_nested_permissions_do_not_count(self):
        source = self.trusted_dispatch().replace(REPOSITORY_GUARD, 'true # ' + REPOSITORY_GUARD)
        self.assertIn('smoke: missing repository guard', workflow_security_errors(source))
        source = self.trusted_dispatch().replace('permissions:\n  contents: read\n', '')
        source = source.replace('    runs-on:', '    permissions:\n      contents: read\n    runs-on:')
        self.assertIn('missing top-level permissions', workflow_security_errors(source))


if __name__ == '__main__':
    unittest.main()
