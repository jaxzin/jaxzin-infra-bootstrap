#!/usr/bin/env bash
#
# Prepare the collection for a release at the given version.
#
# Invoked by semantic-release (@semantic-release/exec prepareCmd) as:
#   ./scripts/release-prepare.sh <version>
#
# It bumps the version in galaxy.yml and builds the collection tarball
# (jaxzin-infra-<version>.tar.gz) into the repo root, ready for
# `ansible-galaxy collection publish`.
set -euo pipefail

VERSION="${1:?usage: release-prepare.sh <version>}"

# Bump the single top-level `version:` key in galaxy.yml.
python3 - "$VERSION" <<'PY'
import re
import sys

version = sys.argv[1]
path = "galaxy.yml"
with open(path) as fh:
    content = fh.read()
new, count = re.subn(r"(?m)^version:.*$", f"version: {version}", content)
if count != 1:
    sys.exit(f"release-prepare: expected exactly one 'version:' line in {path}, found {count}")
with open(path, "w") as fh:
    fh.write(new)
print(f"release-prepare: galaxy.yml version -> {version}")
PY

# Build the collection tarball into the repo root.
ansible-galaxy collection build --force --output-path .
