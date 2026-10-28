#!/bin/bash
# Required local gate; never dispatches a hosted job or modifies repository settings.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ci
manifest() {
  python3 - <<'PY'
import hashlib, json, os, pathlib, subprocess
root = pathlib.Path.cwd().resolve()
# A nonsynced build mirror is allowed only when every input matches the real checkout.
source = pathlib.Path(os.environ.get('TINYSTATS_VALIDATION_SOURCE_ROOT', str(root))).resolve()
reported_root = pathlib.Path(subprocess.check_output([
    'git', '-C', str(source), 'rev-parse', '--show-toplevel'], text=True).strip()).resolve()
if reported_root != source:
    raise RuntimeError('Validation source must be a Git checkout root')
paths = subprocess.check_output([
    'git', '-C', str(source), 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--',
    'Sources', 'Tests', 'Resources', 'scripts', '.github', 'Package.swift',
    'Package.resolved', 'VERSION', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
    'AGENTS.md',
]).decode().split('\0')
inputs = {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
          for name in sorted(set(paths)) if name and (source / name).is_file()}
for name, digest in inputs.items():
    if hashlib.sha256((source / name).read_bytes()).hexdigest() != digest:
        raise RuntimeError('Build mirror does not match authoritative input: ' + name)
print(json.dumps({
    'base_commit': subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip(),
    'build_mirror': source != root,
    'inputs': inputs,
}, indent=2, sort_keys=True))
PY
}
manifest > build/ci/source-manifest.json
# Require a completed pipeline, not merely an old summary file.
rm -f build/ci/LOCAL-PASS.txt
git diff --check
swift format lint --strict --recursive Sources Tests Package.swift 2>&1 | tee build/ci/format.txt
scripts/ci-macos.sh "$(uname -m)" "$(sw_vers -productVersion | cut -d. -f1)" universal
manifest > build/ci/source-manifest-after.json
cmp build/ci/source-manifest.json build/ci/source-manifest-after.json
printf 'Local validation passed for the inputs in source-manifest.json. Native host scope only.\n' | tee build/ci/LOCAL-PASS.txt
