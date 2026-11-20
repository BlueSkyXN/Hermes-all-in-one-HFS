---
title: Hermes Agent All-in-One
colorFrom: yellow
colorTo: indigo
sdk: docker
app_port: 7860
suggested_hardware: cpu-basic
pinned: false
license: gpl-3.0
---

# Hermes Agent All-in-One for Hugging Face Space

This repository packages [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
as a Hugging Face Docker Space. It exposes the upstream browser Dashboard and
embedded Chat on one public port without copying the upstream source into this
wrapper repository.

## Deployment target

- GitHub wrapper: <https://github.com/BlueSkyXN/Hermes-all-in-one-HFS>
- Hugging Face Space: <https://huggingface.co/spaces/BlueSkyXN/Hermes-all-in-one-HFS>
- Live app: <https://blueskyxn-hermes-all-in-one-hfs.hf.space>
- Space mode: Docker, protected preview, `cpu-basic`
- Public port: `7860`
- Persistent state: private bucket mounted at `/data`

## Upstream pin

The wrapper derives from one immutable upstream release image:

```text
repository:     https://github.com/NousResearch/hermes-agent
release:        v0.23.3 (Hermes Agent 0.23.3)
source commit:  caafe5389ae585ef77387a962aee05b1bcf17029
image:          nousresearch/hermes-agent:v0.23.3
image digest:   sha256:3e9fe4c6ef36490f43aa0d0d80f9df64e9c92a576eee3042f1a97c8813c05355
config schema:  54
```

The digest is the multi-architecture manifest published by the upstream release.
The image build checks that commit and base version in `/opt/hermes/install-stamp.json`;
startup checks the commit again.
The wrapper extends that release image, fixes its runtime account to UID/GID
`1000`, bypasses the root/s6 bootstrap that is incompatible with HF Spaces, and
keeps `/opt/hermes` immutable. Mutable state belongs under `/data/hermes`; the
UV download cache is redirected to ephemeral `/tmp/hermes-cache` so rebuildable
cache objects do not consume the persistent bucket.

## Runtime

```text
Hugging Face proxy
        |
        v
Hermes Dashboard / FastAPI :7860
  |- Web Dashboard and embedded Chat at /
  |- public liveness at /api/health
  `- authenticated management APIs and WebSockets under /api

/data/hermes
  |- config.yaml and provider credentials
  |- sessions, memories, skills, plans, and workspace
  |- SQLite databases and logs
  `- Dashboard and gateway runtime state
```

This first deployment is deliberately **UI-first**. It does not start the
separate messaging gateway or expose Hermes' OpenAI-compatible `/v1/*` service.
Those services use a different internal process and port; exposing both would
require a reverse proxy and multi-process lifecycle that are not needed for the
requested browser deployment.

The Space runs `hermes dashboard --host 0.0.0.0 --port 7860 --no-open` through
`entrypoint.sh`. Non-loopback Dashboard binds are fail-closed upstream, so the
wrapper requires these Space settings:

```text
Variable: ADMIN_USERNAME
Secret:   ADMIN_PASSWORD
Secret:   OPS_TOKEN
```

The wrapper maps `ADMIN_USERNAME` and `ADMIN_PASSWORD` to the upstream Dashboard
Basic Auth variables. It maps `OPS_TOKEN` to the upstream session-signing secret
so browser login sessions survive Space restarts. `OPENROUTER_API_KEY` is an
optional Space Secret for the default inference provider; other upstream
providers can be configured through the authenticated Dashboard after launch.

## HFS classification

```text
standard:       HFS v3.0
project_class:  preview
target_role:    primary
sovereignty:    port
lane:           artifact
version_source: tag
visibility:     protected Space / private bucket
```

The artifact lane uses the upstream's immutable, CI-tested release image rather
than rebuilding its multi-gigabyte Python, Node, Chromium, SQLite, and s6 stack
inside every Space build. This is recorded as an HFS deviation because the
application layer remains an upstream business image.

## Persistence boundary

Mount a private Hugging Face Storage Bucket read-write at `/data` before relying
on sessions, memory, skills, provider configuration, or OAuth state. Startup now
fails closed without the mount. A new empty bucket must also contain the
`hermes/` prefix before the UID `1000` process can create its directory tree:

```bash
./scripts/prepare-bucket-prefix.sh --apply
```

That command performs the one intentional remote write: it creates the
non-sensitive `hermes/.hfs-bucket-seed` marker (`{}`), then reads back both the
exact marker content and the read-write `/data` mount. Routine checks use
`--check`, which is read-only. The marker is part of the deployment contract,
not application data.

Only one Hermes instance may write a given `HERMES_HOME`. Do not mount the same
bucket path into multiple concurrently running Hermes Spaces. Storage Bucket
SQLite behavior must be accepted through an actual write, Space restart, and
readback; a `RUNNING` stage or HTTP health response alone does not prove durable
state. Every startup also performs a throwaway SQLite WAL transaction,
reopen/readback, cleanup, and read-only `PRAGMA quick_check` on existing Hermes
databases. It then migrates a compatible `config.yaml` to the schema baked into
the pinned upstream image, with backup, rollback, and post-migration readback;
an explicitly ancient or newer-than-runtime schema fails closed.

The tracked [`hfs-dev.toml`](hfs-dev.toml) is the deployment declaration. Hermes
business settings remain in the upstream `/data/hermes/config.yaml`; this
wrapper intentionally does not invent a second application `config.toml`.

## Local validation boundary

The wrapper can be built locally, but doing so pulls and executes the roughly
1 GB compressed upstream image and writes Docker build cache. Keep routine
validation static and let the Space perform the first integration build unless
an explicit local third-party execution check is required.

```bash
./scripts/static-check.sh
./scripts/prepare-bucket-prefix.sh --check
docker build -t hermes-all-in-one-hfs .
```

After deployment:

```bash
curl -fsS https://blueskyxn-hermes-all-in-one-hfs.hf.space/api/health
```

## Known platform limits

- `cpu-basic` Spaces sleep when idle, interrupting unattended gateway and cron
  work; this preview is an on-demand browser app, not an always-on bot host.
- The container has no host Docker socket, so Hermes' Docker terminal backend is
  unavailable. The default local backend executes inside the Space sandbox.
- Model inference and optional tools require their own provider credentials and
  outbound HTTPS availability.
- Basic Auth is a single shared credential without MFA. A direct `hf.space`
  domain can remain internet-reachable even when HF reports the repository as
  private/protected, so Basic Auth is the effective application access gate for
  this preview. Keep it as an explicitly accepted preview risk; for a durable
  public deployment, use upstream Nous OAuth or a self-hosted OIDC provider.

## Acceptance status

The current deliverable is a Dashboard preview, not a fully accepted Hermes
Agent service. `RUNNING`, `/api/health`, authenticated Dashboard access, and the
persistence preflight prove the wrapper/runtime layer. Dashboard business
acceptance still requires a configured model provider and one real
prompt/response persisted across restart. The messaging gateway, channels,
cron, and `/v1/*` surfaces remain out of scope unless they are explicitly
selected and separately accepted. Until then, `gateway_running=false` and an
overall degraded `/api/status` are expected consequences of the UI-first scope.

## Licensing

The wrapper files in this repository are provided under GPL-3.0. The upstream
Hermes Agent application remains MIT-licensed and retains its license and notices
inside the pinned image.
