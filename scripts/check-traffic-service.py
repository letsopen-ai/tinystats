#!/usr/bin/env python3
"""Audit direct Mach-O dependencies of the read-only traffic service, without executing it."""
import argparse
import json
import pathlib
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", type=pathlib.Path)
parser.add_argument("--output", type=pathlib.Path)
args = parser.parse_args()
binary = args.binary.resolve(strict=True)
architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
if not architectures or not set(architectures) <= {"arm64", "x86_64"}:
    raise SystemExit("Unexpected service architecture")
allowed_frameworks = {"CoreFoundation", "Foundation", "Security"}
report = {"architectures": architectures, "direct_dependencies": {}}
for architecture in architectures:
    output = subprocess.check_output(["otool", "-arch", architecture, "-L", str(binary)], text=True)
    dependencies = []
    for line in output.splitlines()[1:]:
        match = re.match(r"\s+(.+?) \(compatibility version ", line)
        if not match:
            raise SystemExit("Unrecognized dependency output: " + line)
        dependency = match.group(1)
        framework = re.fullmatch(r"/System/Library/Frameworks/([^/]+)\.framework/.+", dependency)
        if framework:
            if framework.group(1) not in allowed_frameworks:
                raise SystemExit("Unrelated framework in traffic service: " + dependency)
        elif not dependency.startswith("/usr/lib/"):
            raise SystemExit("Non-system dependency in traffic service: " + dependency)
        dependencies.append(dependency)
    if not dependencies:
        raise SystemExit("Missing service dependencies")
    report["direct_dependencies"][architecture] = dependencies
encoded = json.dumps(report, indent=2) + "\n"
if args.output:
    args.output.write_text(encoded)
print("Traffic service dependencies passed for " + ", ".join(architectures))
