#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
cd "${root}"

bash -n entrypoint.sh

ROOT="${root}" python3 - <<'PY'
import os
import pathlib
import re
import tomllib

root = pathlib.Path(os.environ["ROOT"])

for name in ("hfs-dev.toml", "config.toml"):
    with (root / name).open("rb") as handle:
        tomllib.load(handle)

readme = (root / "README.md").read_text(encoding="utf-8")
for line in ("sdk: docker", "app_port: 7860", "license: gpl-3.0"):
    if line not in readme:
        raise SystemExit(f"README.md is missing Space metadata: {line}")

dockerfile = (root / "Dockerfile").read_text(encoding="utf-8")
entrypoint = (root / "entrypoint.sh").read_text(encoding="utf-8")

digest_match = re.search(r"sha256:[0-9a-f]{64}", dockerfile)
if digest_match is None:
    raise SystemExit("Dockerfile does not pin the upstream image digest")

source_match = re.search(r"HERMES_SOURCE_REF=([0-9a-f]{40})", dockerfile)
if source_match is None:
    raise SystemExit("Dockerfile does not declare a 40-character upstream source ref")

expected = source_match.group(1)
for name, content in (("README.md", readme), ("entrypoint.sh", entrypoint)):
    if expected not in content:
        raise SystemExit(f"{name} does not carry the declared upstream source ref")

required_snippets = (
    "USER hermes",
    "HERMES_HOME=/data/hermes",
    "EXPOSE 7860",
    'ENTRYPOINT ["/usr/local/bin/hermes-hfs-entrypoint"]',
)
for snippet in required_snippets:
    if snippet not in dockerfile:
        raise SystemExit(f"Dockerfile is missing runtime contract: {snippet}")

for key in ("ADMIN_USERNAME", "ADMIN_PASSWORD", "OPS_TOKEN"):
    if key not in entrypoint:
        raise SystemExit(f"entrypoint.sh is missing required auth input: {key}")

print("static contract: PASS")
PY

if [[ -d .git ]]; then
  git diff --check
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck entrypoint.sh scripts/static-check.sh
fi

if command -v hadolint >/dev/null 2>&1; then
  hadolint Dockerfile
fi

printf 'static checks: PASS\n'
