#!/usr/bin/env python3
"""Read-mode regressions: never launch MTCore or modify saved observations."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

GUARDIAN = Path(__file__).resolve().with_name("MTGuardianX")


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        core = self.root / "MTCore"
        core.write_text("#!/bin/sh\nexit 99\n")
        core.chmod(0o700)
        self.status = self.root / "state" / "Demo_Profile" / "status.json"
        self.logs = self.root / "logs"
        self.config = self.root / "test.conf"
        self.config.write_text(f"MT_CORE_DIR='{self.root}'\n"
                               "MT_CORE_PROFILE=Demo_Profile\n"
                               f"MTGX_STATE_ROOT='{self.root}/state'\n"
                               f"MTGX_LOG_ROOT='{self.logs}'\n")
        self.config.chmod(0o600)

    def invoke(self, mode):
        result = subprocess.run(["bash", str(GUARDIAN), "--config",
                                 str(self.config), mode], check=True,
                                capture_output=True, text=True)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)

    def test_read_modes_preserve_saved_status_bytes_and_mtime(self):
        # Calling write_status from either CLI mode destroys this real snapshot.
        snapshot = {"ts": "2020-01-02T03:04:05Z", "epoch": 1577934245,
                    "state": "running", "guardian_pid": 12345,
                    "current_core_pid": 23456, "restart_count": 3,
                    "process": {"pid": 23456, "running": True}}
        original = (json.dumps(snapshot, indent=2) + "\n").encode()
        self.status.parent.mkdir(parents=True)
        self.status.write_bytes(original)
        os.utime(self.status, (1577934245, 1577934245))
        original_mtime = self.status.stat().st_mtime_ns
        for mode in ("--status", "--dump-report"):
            with self.subTest(mode=mode):
                result = self.invoke(mode)
                self.assertEqual(self.status.read_bytes(), original)
                self.assertEqual(self.status.stat().st_mtime_ns, original_mtime)
                self.assertEqual(result if mode == "--status" else result["status"], snapshot)

    def test_missing_snapshot_reports_unavailable_without_creating_state(self):
        # Empty CLI defaults must never become a fabricated health observation.
        for mode in ("--status", "--dump-report"):
            with self.subTest(mode=mode):
                result = self.invoke(mode)
                status = result if mode == "--status" else result["status"]
                self.assertTrue(status["status_unavailable"])
                self.assertEqual(status["state"], "unavailable")
                self.assertNotIn("process", status)
                self.assertNotIn("guardian_pid", status)
                self.assertNotIn("ts", status)
                self.assertFalse(self.status.parent.parent.exists())
                self.assertFalse(self.logs.exists())

    def test_report_escapes_control_characters_in_log_snapshot(self):
        # ANSI ESC, backspace and form feed in MTCore logs must remain valid JSON.
        self.logs.mkdir()
        contents = ("ANSI \x1b[31merror\x1b[0m\nbackspace \b formfeed \f"
                    + " all controls: " + "".join(chr(n) for n in range(1, 32))
                    + r" literal \u001b and quotes \" end")
        (self.logs / "Demo_Profile.last-crash.log").write_text(contents)
        result = self.invoke("--dump-report")
        self.assertEqual(result["crash_snapshot"], contents)


if __name__ == "__main__":
    unittest.main()
