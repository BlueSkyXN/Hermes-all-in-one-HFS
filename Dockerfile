# syntax=docker/dockerfile:1.7

ARG HERMES_IMAGE=nousresearch/hermes-agent:v2026.8.3@sha256:16788311e2fa3035456bdc1bafb8ec2b1777db64ebf020af9bb7eb73c3712c9e

FROM ${HERMES_IMAGE}

ARG HERMES_RELEASE=v2026.8.3
ARG HERMES_VERSION=0.20.0
ARG HERMES_SOURCE_REF=3c27eb6234bf91b8ceee9e9071591b31e9b148cb
ARG HERMES_CONFIG_VERSION=33

LABEL org.opencontainers.image.title="Hermes Agent All-in-One HFS" \
      org.opencontainers.image.description="Hermes Agent Dashboard adapted for a Hugging Face Docker Space" \
      org.opencontainers.image.source="https://github.com/BlueSkyXN/Hermes-all-in-one-HFS" \
      org.opencontainers.image.version="${HERMES_RELEASE}" \
      org.opencontainers.image.revision="${HERMES_SOURCE_REF}" \
      org.opencontainers.image.licenses="GPL-3.0-only AND MIT" \
      io.huggingface.hfs.upstream.image="nousresearch/hermes-agent:v2026.8.3@sha256:16788311e2fa3035456bdc1bafb8ec2b1777db64ebf020af9bb7eb73c3712c9e" \
      io.huggingface.hfs.upstream.version="${HERMES_VERSION}"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
    HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist \
    HERMES_TUI_DIR=/opt/hermes/ui-tui \
    HERMES_HOME=/data/hermes \
    HERMES_WRITE_SAFE_ROOT=/data/hermes \
    HERMES_LAZY_INSTALL_TARGET=/data/hermes/lazy-packages \
    HERMES_DISABLE_LAZY_INSTALLS=1 \
    HERMES_DASHBOARD_HOST=0.0.0.0 \
    HERMES_DASHBOARD_PORT=7860 \
    HERMES_HFS_EXPECTED_SOURCE_REF=${HERMES_SOURCE_REF} \
    HERMES_HFS_EXPECTED_CONFIG_VERSION=${HERMES_CONFIG_VERSION} \
    XDG_CACHE_HOME=/tmp/hermes-cache \
    UV_CACHE_DIR=/tmp/hermes-cache/uv \
    PORT=7860 \
    HOME=/data/hermes \
    PATH=/opt/hermes/bin:/opt/hermes/.venv/bin:/data/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY entrypoint.sh /usr/local/bin/hermes-hfs-entrypoint
COPY scripts/runtime-preflight.py /usr/local/lib/hermes-hfs/runtime-preflight.py

RUN set -eux; \
    groupmod --gid 1000 hermes; \
    usermod --uid 1000 --gid 1000 --home /data/hermes hermes; \
    mkdir -p /data/hermes /data/hermes/home /data/hermes/lazy-packages; \
    chown -R hermes:hermes /data; \
    chmod 0755 /usr/local/bin/hermes-hfs-entrypoint; \
    test -x /opt/hermes/.venv/bin/hermes; \
    test -f /opt/hermes/.hermes_build_sha; \
    test "$(tr -d '[:space:]' < /opt/hermes/.hermes_build_sha)" = "${HERMES_SOURCE_REF}"; \
    test "$(/opt/hermes/.venv/bin/python -c 'import sqlite3; print(sqlite3.sqlite_version)')" = "3.53.4"; \
    test "$(/opt/hermes/.venv/bin/python -c 'from hermes_cli import __version__; print(__version__)')" = "${HERMES_VERSION}"; \
    test "$(/opt/hermes/.venv/bin/python -c 'from hermes_cli.config_defaults import DEFAULT_CONFIG; print(DEFAULT_CONFIG.get("_config_version"))')" = "${HERMES_CONFIG_VERSION}"; \
    /opt/hermes/.venv/bin/python -m py_compile /usr/local/lib/hermes-hfs/runtime-preflight.py; \
    rm -rf /usr/local/lib/hermes-hfs/__pycache__

USER hermes
WORKDIR /data/hermes

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD ["sh", "-c", "curl -fsS http://127.0.0.1:${PORT:-7860}/api/health >/dev/null"]

ENTRYPOINT ["/usr/local/bin/hermes-hfs-entrypoint"]
