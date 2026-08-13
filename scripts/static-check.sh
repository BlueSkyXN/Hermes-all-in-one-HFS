#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
cd "${root}"

bash -n entrypoint.sh
bash -n scripts/prepare-bucket-prefix.sh

ROOT="${root}" python3 - <<'PY'
import os
import pathlib
import re
import tomllib

root = pathlib.Path(os.environ["ROOT"])

for name in ("hfs-dev.toml",):
    with (root / name).open("rb") as handle:
        tomllib.load(handle)

readme = (root / "README.md").read_text(encoding="utf-8")
for line in ("sdk: docker", "app_port: 7860", "license: gpl-3.0"):
    if line not in readme:
        raise SystemExit(f"README.md is missing Space metadata: {line}")

dockerfile = (root / "Dockerfile").read_text(encoding="utf-8")
entrypoint = (root / "entrypoint.sh").read_text(encoding="utf-8")
preflight = (root / "scripts/runtime-preflight.py").read_text(encoding="utf-8")

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
    "XDG_CACHE_HOME=/tmp/hermes-cache",
    "EXPOSE 7860",
    'ENTRYPOINT ["/usr/local/bin/hermes-hfs-entrypoint"]',
    'DEFAULT_CONFIG.get("_config_version")',
)
for snippet in required_snippets:
    if snippet not in dockerfile:
        raise SystemExit(f"Dockerfile is missing runtime contract: {snippet}")

if r'DEFAULT_CONFIG[\"_config_version\"]' in dockerfile:
    raise SystemExit("Dockerfile must not pass escaped quotes to the Python schema check")

for key in ("ADMIN_USERNAME", "ADMIN_PASSWORD", "OPS_TOKEN"):
    if key not in entrypoint:
        raise SystemExit(f"entrypoint.sh is missing required auth input: {key}")

for snippet in (
    'fail "/data must be a mounted persistent volume"',
    'runtime-preflight.py',
    'prepare-bucket-prefix.sh --apply',
):
    if snippet not in entrypoint:
        raise SystemExit(f"entrypoint.sh is missing startup contract: {snippet}")

for snippet in ("migration_action", "PRAGMA journal_mode=WAL", "PRAGMA quick_check"):
    if snippet not in preflight:
        raise SystemExit(f"runtime-preflight.py is missing contract: {snippet}")

print("static contract: PASS")
PY

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py'
PYTHONDONTWRITEBYTECODE=1 python3 scripts/runtime-preflight.py --self-test

if [[ -d .git ]]; then
  git diff --check
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck entrypoint.sh scripts/static-check.sh scripts/prepare-bucket-prefix.sh
fi

if command -v hadolint >/dev/null 2>&1; then
  hadolint Dockerfile
fi

printf 'static checks: PASS\n'
