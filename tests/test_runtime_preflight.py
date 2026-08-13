from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "runtime-preflight.py"
SPEC = importlib.util.spec_from_file_location("hermes_hfs_runtime_preflight", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
PREFLIGHT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREFLIGHT)


class MigrationDecisionTests(unittest.TestCase):
    def test_fresh_unversioned_config_migrates(self) -> None:
        self.assertEqual(
            PREFLIGHT.migration_action(
                current=0,
                latest=33,
                explicit_version=False,
                support_floor=12,
                expected_latest=33,
            ),
            "migrate",
        )

    def test_explicit_ancient_config_fails_closed(self) -> None:
        with self.assertRaises(PREFLIGHT.PreflightError):
            PREFLIGHT.migration_action(
                current=11,
                latest=33,
                explicit_version=True,
                support_floor=12,
                expected_latest=33,
            )

    def test_newer_persisted_config_fails_closed(self) -> None:
        with self.assertRaises(PREFLIGHT.PreflightError):
            PREFLIGHT.migration_action(
                current=34,
                latest=33,
                explicit_version=True,
                support_floor=12,
                expected_latest=33,
            )

    def test_current_config_skips_migration(self) -> None:
        self.assertEqual(
            PREFLIGHT.migration_action(
                current=33,
                latest=33,
                explicit_version=True,
                support_floor=12,
                expected_latest=33,
            ),
            "current",
        )

    def test_runtime_schema_drift_fails_closed(self) -> None:
        with self.assertRaises(PREFLIGHT.PreflightError):
            PREFLIGHT.migration_action(
                current=33,
                latest=34,
                explicit_version=True,
                support_floor=12,
                expected_latest=33,
            )


class MigrationRollbackTests(unittest.TestCase):
    def test_failed_readback_restores_existing_files(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            config = home / "config.yaml"
            env = home / ".env"
            config.write_text("_config_version: 32\n", encoding="utf-8")
            env.write_text("EXISTING=value\n", encoding="utf-8")

            def migrate_with_bad_readback():
                config.write_text("_config_version: 33\n", encoding="utf-8")
                env.write_text("CHANGED=value\n", encoding="utf-8")
                return {"warnings": []}

            with self.assertRaises(PREFLIGHT.PreflightError):
                PREFLIGHT._migrate_with_rollback(
                    home=home,
                    tracked_paths=(config, env),
                    migrate=migrate_with_bad_readback,
                    read_version=lambda: (32, 33),
                    latest=33,
                )

            self.assertEqual(config.read_text(encoding="utf-8"), "_config_version: 32\n")
            self.assertEqual(env.read_text(encoding="utf-8"), "EXISTING=value\n")

    def test_failed_migration_removes_new_tracked_files(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            config = home / "config.yaml"
            env = home / ".env"

            def fail_after_writes():
                config.write_text("_config_version: 33\n", encoding="utf-8")
                env.write_text("NEW=value\n", encoding="utf-8")
                raise RuntimeError("migration failed")

            with self.assertRaises(PREFLIGHT.PreflightError):
                PREFLIGHT._migrate_with_rollback(
                    home=home,
                    tracked_paths=(config, env),
                    migrate=fail_after_writes,
                    read_version=lambda: (33, 33),
                    latest=33,
                )

            self.assertFalse(config.exists())
            self.assertFalse(env.exists())


class PersistenceProbeTests(unittest.TestCase):
    def test_probe_writes_reads_and_cleans_up(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            PREFLIGHT.probe_persistence(home)
            self.assertEqual(list(home.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
