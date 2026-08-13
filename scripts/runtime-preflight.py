#!/usr/bin/env python3
"""Fail-closed runtime checks for the Hermes Hugging Face wrapper."""

from __future__ import annotations

import argparse
import os
import shutil
import sqlite3
import tempfile
from collections.abc import Callable, Iterable, Mapping
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4


class PreflightError(RuntimeError):
    """Raised when persisted runtime state is unsafe to start."""


def migration_action(
    *,
    current: int,
    latest: int,
    explicit_version: bool,
    support_floor: int,
    expected_latest: int | None,
) -> str:
    """Return ``current`` or ``migrate``; reject incompatible schema states."""
    if expected_latest is not None and latest != expected_latest:
        raise PreflightError(
            f"upstream config schema is {latest}, expected {expected_latest}"
        )
    if current > latest:
        raise PreflightError(
            f"persisted config schema {current} is newer than runtime schema {latest}"
        )
    if current == latest:
        return "current"
    if explicit_version and current < support_floor:
        raise PreflightError(
            f"persisted config schema {current} is below migration floor {support_floor}"
        )
    return "migrate"


def _backup_files(home: Path, paths: Iterable[Path]) -> dict[Path, Path]:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_dir = home / "backups" / f"config-migration-{stamp}"
    backups: dict[Path, Path] = {}
    for source in paths:
        if not source.is_file():
            continue
        backup_dir.mkdir(parents=True, exist_ok=True)
        destination = backup_dir / source.name
        suffix = 1
        while destination.exists():
            destination = backup_dir / f"{source.name}.{suffix}"
            suffix += 1
        shutil.copy2(source, destination)
        backups[source] = destination
    return backups


def _restore_files(backups: dict[Path, Path]) -> None:
    for destination, source in backups.items():
        shutil.copy2(source, destination)


def _remove_new_files(original_paths: Iterable[Path], tracked_paths: Iterable[Path]) -> None:
    original = set(original_paths)
    for path in tracked_paths:
        if path not in original:
            path.unlink(missing_ok=True)


def _migrate_with_rollback(
    *,
    home: Path,
    tracked_paths: Iterable[Path],
    migrate: Callable[[], Mapping[str, Any]],
    read_version: Callable[[], tuple[int, int]],
    latest: int,
) -> None:
    paths = tuple(tracked_paths)
    original_paths = tuple(path for path in paths if path.is_file())
    backups = _backup_files(home, original_paths)
    try:
        results = migrate()
        warning_count = len(results.get("warnings", ()))
        if warning_count:
            print(
                f"[hermes-hfs] config migration completed with {warning_count} warning(s)",
                file=os.sys.stderr,
            )
        migrated, migrated_latest = read_version()
        if migrated != migrated_latest or migrated != latest:
            raise PreflightError(
                f"config migration readback is {migrated}, expected {latest}"
            )
    except Exception as exc:
        try:
            _restore_files(backups)
            _remove_new_files(original_paths, paths)
        except Exception as rollback_exc:
            raise PreflightError(
                f"config migration and rollback failed: {type(rollback_exc).__name__}"
            ) from rollback_exc
        if isinstance(exc, PreflightError):
            raise
        raise PreflightError(f"config migration failed: {type(exc).__name__}") from exc


def migrate_config_schema(home: Path) -> None:
    """Run the pinned upstream migration with backup, rollback, and readback."""
    import yaml
    from hermes_cli.config import (
        check_config_version,
        get_config_path,
        get_env_path,
        migrate_config,
    )
    from hermes_cli.config_migrations import SUPPORT_FLOOR_VERSION

    config_path = get_config_path()
    try:
        raw = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise PreflightError(f"config.yaml cannot be parsed: {type(exc).__name__}") from exc
    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise PreflightError("config.yaml root must be a mapping")

    current, latest = check_config_version()
    expected_raw = os.environ.get("HERMES_HFS_EXPECTED_CONFIG_VERSION", "").strip()
    expected = int(expected_raw) if expected_raw else None
    action = migration_action(
        current=current,
        latest=latest,
        explicit_version="_config_version" in raw,
        support_floor=SUPPORT_FLOOR_VERSION,
        expected_latest=expected,
    )
    if action == "current":
        print(f"[hermes-hfs] config schema {current}: current")
        return

    _migrate_with_rollback(
        home=home,
        tracked_paths=(config_path, get_env_path()),
        migrate=lambda: migrate_config(interactive=False, quiet=True),
        read_version=check_config_version,
        latest=latest,
    )
    print(f"[hermes-hfs] config schema migrated {current} -> {latest}")


def _remove_probe_files(path: Path) -> None:
    for suffix in ("", "-journal", "-shm", "-wal"):
        candidate = Path(f"{path}{suffix}")
        try:
            candidate.unlink(missing_ok=True)
        except OSError as exc:
            raise PreflightError(f"cannot remove persistence probe: {type(exc).__name__}") from exc


def probe_persistence(home: Path) -> None:
    """Verify transactional SQLite write, reopen/readback, and existing DB health."""
    probe = home / f".hfs-persistence-probe-{os.getpid()}-{uuid4().hex}.sqlite3"
    try:
        with closing(sqlite3.connect(probe, timeout=5.0)) as connection:
            mode = connection.execute("PRAGMA journal_mode=WAL").fetchone()
            if not mode or str(mode[0]).lower() != "wal":
                raise PreflightError("persistence probe could not enable SQLite WAL")
            connection.execute("CREATE TABLE probe (value TEXT NOT NULL)")
            connection.execute("INSERT INTO probe VALUES ('ok')")
            connection.commit()

        with closing(sqlite3.connect(probe, timeout=5.0)) as connection:
            value = connection.execute("SELECT value FROM probe").fetchone()
            integrity = connection.execute("PRAGMA quick_check").fetchone()
            if value != ("ok",) or integrity != ("ok",):
                raise PreflightError("persistence probe readback or integrity check failed")

        for name in ("state.db", "projects.db", "response_store.db"):
            database = home / name
            if not database.is_file():
                continue
            uri = f"file:{database.as_posix()}?mode=ro"
            with closing(sqlite3.connect(uri, uri=True, timeout=5.0)) as connection:
                result = connection.execute("PRAGMA quick_check").fetchone()
                if result != ("ok",):
                    raise PreflightError(f"{name} failed SQLite quick_check")
    finally:
        _remove_probe_files(probe)
    print("[hermes-hfs] persistence transaction and integrity probes: PASS")


def run(home: Path, *, migrate: bool = True) -> None:
    resolved = home.resolve(strict=True)
    if home.is_symlink():
        raise PreflightError("HERMES_HOME must be a real, canonical directory")
    home = resolved
    if not os.access(home, os.W_OK):
        raise PreflightError("HERMES_HOME is not writable")
    if migrate:
        migrate_config_schema(home)
    probe_persistence(home)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    try:
        if args.self_test:
            with tempfile.TemporaryDirectory(prefix="hermes-hfs-preflight-") as root:
                run(Path(root), migrate=False)
            print("[hermes-hfs] runtime preflight self-test: PASS")
            return 0
        if args.home is None:
            parser.error("--home is required unless --self-test is used")
        run(args.home)
        return 0
    except (OSError, sqlite3.Error, PreflightError, ValueError) as exc:
        print(f"[hermes-hfs] ERROR: {exc}", file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
