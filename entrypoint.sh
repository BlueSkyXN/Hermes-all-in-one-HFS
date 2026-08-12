#!/usr/bin/env bash
set -euo pipefail

readonly install_dir="/opt/hermes"
readonly data_root="${HERMES_HOME:-/data/hermes}"
readonly expected_uid="1000"
readonly expected_source_ref="${HERMES_HFS_EXPECTED_SOURCE_REF:-3c27eb6234bf91b8ceee9e9071591b31e9b148cb}"

fail() {
  printf '[hermes-hfs] ERROR: %s\n' "$*" >&2
  exit 1
}

is_descendant() {
  case "$1" in
    /data/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_placeholder() {
  local value="${1,,}"
  case "${value}" in
    ""|changeme|change-me|password|secret|placeholder|example|test|admin) return 0 ;;
    *) return 1 ;;
  esac
}

test "$(id -u)" = "${expected_uid}" \
  || fail "runtime UID must be ${expected_uid} on Hugging Face Spaces"
test -d "${install_dir}" || fail "immutable Hermes install is missing"
test -x "${install_dir}/.venv/bin/hermes" || fail "Hermes executable is missing"
test -f "${install_dir}/.hermes_build_sha" || fail "upstream build provenance is missing"
test "$(tr -d '[:space:]' < "${install_dir}/.hermes_build_sha")" = "${expected_source_ref}" \
  || fail "upstream image source does not match the declared release commit"

is_descendant "${data_root}" \
  || fail "HERMES_HOME must be a child of /data"
test ! -L "${data_root}" || fail "HERMES_HOME must not be a symlink"
mkdir -p \
  "${data_root}" \
  "${data_root}/backups" \
  "${data_root}/cron" \
  "${data_root}/home" \
  "${data_root}/hooks" \
  "${data_root}/lazy-packages" \
  "${data_root}/logs/gateways" \
  "${data_root}/memories" \
  "${data_root}/pairing" \
  "${data_root}/plans" \
  "${data_root}/platforms/pairing" \
  "${data_root}/profiles" \
  "${data_root}/sessions" \
  "${data_root}/skills" \
  "${data_root}/skins" \
  "${data_root}/workspace"
test -w "${data_root}" || fail "HERMES_HOME is not writable"

if command -v mountpoint >/dev/null 2>&1 && mountpoint -q /data; then
  printf '[hermes-hfs] persistent volume detected at /data\n'
else
  printf '[hermes-hfs] WARNING: /data is not a mounted volume; Hermes state is ephemeral\n' >&2
fi

seed_once() {
  local source="$1"
  local destination="$2"
  if [[ ! -e "${destination}" ]]; then
    install -m 0640 "${source}" "${destination}"
  fi
}

seed_once "${install_dir}/cli-config.yaml.example" "${data_root}/config.yaml"
seed_once "${install_dir}/docker/SOUL.md" "${data_root}/SOUL.md"

if [[ ! -e "${data_root}/.env" ]]; then
  install -m 0600 /dev/null "${data_root}/.env"
fi
chmod 0600 "${data_root}/.env"

if [[ -f "${install_dir}/tools/skills_sync.py" ]]; then
  "${install_dir}/.venv/bin/python" "${install_dir}/tools/skills_sync.py" \
    || printf '[hermes-hfs] WARNING: bundled skill sync failed; continuing with the existing skill set\n' >&2
fi

if [[ -z "${HERMES_DASHBOARD_OAUTH_CLIENT_ID:-}" && -z "${HERMES_DASHBOARD_OIDC_ISSUER:-}" ]]; then
  : "${ADMIN_USERNAME:?ADMIN_USERNAME is required when OAuth/OIDC is not configured}"
  : "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required when OAuth/OIDC is not configured}"
  : "${OPS_TOKEN:?OPS_TOKEN is required for stable Dashboard sessions}"
  [[ "${#ADMIN_PASSWORD}" -ge 12 ]] \
    || fail "ADMIN_PASSWORD must be at least 12 characters"
  [[ "${#OPS_TOKEN}" -ge 16 ]] \
    || fail "OPS_TOKEN must be at least 16 characters"
  ! is_placeholder "${ADMIN_PASSWORD}" \
    || fail "ADMIN_PASSWORD must not use a placeholder value"
  ! is_placeholder "${OPS_TOKEN}" \
    || fail "OPS_TOKEN must not use a placeholder value"

  export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="${ADMIN_USERNAME}"
  export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="${ADMIN_PASSWORD}"
  export HERMES_DASHBOARD_BASIC_AUTH_SECRET="${OPS_TOKEN}"
fi

export HOME="${data_root}"
export HERMES_HOME="${data_root}"
export HERMES_WRITE_SAFE_ROOT="${data_root}"
export HERMES_LAZY_INSTALL_TARGET="${data_root}/lazy-packages"
export HERMES_DASHBOARD_HOST="${HERMES_DASHBOARD_HOST:-0.0.0.0}"
export HERMES_DASHBOARD_PORT="${PORT:-${HERMES_DASHBOARD_PORT:-7860}}"

cd "${data_root}"

exec "${install_dir}/.venv/bin/hermes" dashboard \
  --host "${HERMES_DASHBOARD_HOST}" \
  --port "${HERMES_DASHBOARD_PORT}" \
  --no-open \
  "$@"
