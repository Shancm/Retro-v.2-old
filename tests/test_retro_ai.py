import contextlib
import importlib.util
import io
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "overlay/opt/retro-ai/retro_ai.py"
SPEC = importlib.util.spec_from_file_location("retro_ai_under_test", SOURCE)
retro_ai = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(retro_ai)


class ClassifyTests(unittest.TestCase):
    def test_ram_normal(self):
        self.assertEqual(retro_ai.classify(40, 85, 92, "ok", True), "ok")

    def test_ram_warning(self):
        self.assertEqual(retro_ai.classify(87, 85, 92, "ok", True), "warn")

    def test_ram_critical(self):
        self.assertEqual(retro_ai.classify(94, 85, 92, "ok", True), "crit")

    def test_ram_warning_hysteresis(self):
        self.assertEqual(retro_ai.classify(83, 85, 92, "warn", True), "warn")

    def test_ram_critical_hysteresis(self):
        self.assertEqual(retro_ai.classify(90, 85, 92, "crit", True), "crit")

    def test_disk_critical(self):
        self.assertEqual(retro_ai.classify(4, 10, 5, "ok", False), "crit")

    def test_disk_critical_hysteresis(self):
        self.assertEqual(retro_ai.classify(7, 10, 5, "crit", False), "crit")

    def test_disk_warning_hysteresis(self):
        self.assertEqual(retro_ai.classify(12, 10, 5, "warn", False), "warn")

    def test_disk_recovery(self):
        self.assertEqual(retro_ai.classify(14, 10, 5, "warn", False), "ok")


class ConfigTests(unittest.TestCase):
    def load_text(self, text):
        tmp = tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False)
        try:
            tmp.write(text)
            tmp.close()
            with mock.patch.object(retro_ai, "CONF_PATH", tmp.name):
                return retro_ai.load_config()
        finally:
            os.unlink(tmp.name)

    def test_config_defaults(self):
        cfg = self.load_text("")
        self.assertEqual(cfg.getint("interval"), 30)

    def test_invalid_interval_falls_back(self):
        cfg = self.load_text("[watch]\ninterval = banana\n")
        self.assertEqual(cfg.getint("interval"), 30)

    def test_interval_below_five_falls_back(self):
        cfg = self.load_text("[watch]\ninterval = 4\n")
        self.assertEqual(cfg.getint("interval"), 30)

    def test_inverted_ram_thresholds_fall_back(self):
        cfg = self.load_text("[watch]\nram_warn = 95\nram_crit = 90\n")
        self.assertEqual((cfg.getint("ram_warn"), cfg.getint("ram_crit")), (85, 92))

    def test_inverted_disk_thresholds_fall_back(self):
        cfg = self.load_text("[watch]\ndisk_warn_free = 4\ndisk_crit_free = 8\n")
        self.assertEqual((cfg.getint("disk_warn_free"), cfg.getint("disk_crit_free")), (10, 5))


class ProbeAndVoiceTests(unittest.TestCase):
    def test_dns_uses_getent_with_timeout(self):
        calls = []

        def fake_run(argv, timeout=10):
            calls.append((argv, timeout))
            return "default via router" if argv[0] == "ip" else "192.0.2.1 deb.debian.org"

        with mock.patch.object(retro_ai, "run", side_effect=fake_run):
            self.assertEqual(retro_ai.network_state(), (True, True))
        self.assertEqual(calls[1][0][:3], ["getent", "hosts", "deb.debian.org"])
        self.assertEqual(calls[1][1], 5)

    def test_speak_rejects_option_injection_speed(self):
        with mock.patch.object(retro_ai.shutil, "which", return_value="/usr/bin/espeak-ng"), \
             mock.patch.object(retro_ai, "have_sound", return_value=True), \
             mock.patch.object(retro_ai.subprocess, "Popen") as popen:
            retro_ai._voice_proc = None
            self.assertFalse(retro_ai.speak("hello", "--stdout"))
            popen.assert_not_called()

    def test_speak_uses_end_of_options_marker(self):
        process = mock.Mock()
        process.poll.return_value = 0
        with mock.patch.object(retro_ai.shutil, "which", return_value="/usr/bin/espeak-ng"), \
             mock.patch.object(retro_ai, "have_sound", return_value=True), \
             mock.patch.object(retro_ai.subprocess, "Popen", return_value=process) as popen:
            retro_ai._voice_proc = None
            self.assertTrue(retro_ai.speak("-dangerous text", "150"))
            self.assertEqual(popen.call_args.args[0][-2:], ["--", "-dangerous text"])

    def test_alert_log_rotates_at_256kib(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "alerts.log"
            log.write_bytes(b"x" * (256 * 1024))
            with mock.patch.object(retro_ai, "RUN_DIR", directory), \
                 mock.patch.object(retro_ai, "ALERT_LOG", str(log)), \
                 contextlib.redirect_stdout(io.StringIO()):
                retro_ai.log_alert("info", "rotated")
            self.assertTrue(Path(str(log) + ".1").exists())
            self.assertIn("rotated", log.read_text(encoding="utf-8"))

    def test_unreadable_journal_is_unknown_not_ok(self):
        cfg = retro_ai.load_config()
        completed = subprocess.CompletedProcess(
            ["journalctl"], 1, stdout="", stderr="Permission denied"
        )
        with mock.patch.object(retro_ai, "read_env_file", return_value={}), \
             mock.patch.object(retro_ai, "ram_stats", return_value=(20.0, 1.0, 4.0)), \
             mock.patch.object(retro_ai, "swap_stats", return_value={"zram": True, "used_mb": 0, "total_mb": 1}), \
             mock.patch.object(retro_ai, "disk_free_pct", return_value=(50.0, 20.0, 40.0)), \
             mock.patch.object(retro_ai.os, "getloadavg", return_value=(0.1, 0.1, 0.1)), \
             mock.patch.object(retro_ai, "cpu_count", return_value=2), \
             mock.patch.object(retro_ai, "temperature", return_value=None), \
             mock.patch.object(retro_ai, "run", return_value=""), \
             mock.patch.object(retro_ai, "unit_active", return_value=True), \
             mock.patch.object(retro_ai, "network_state", return_value=(True, True)), \
             mock.patch.object(retro_ai.subprocess, "run", return_value=completed):
            journal = [row for row in retro_ai.audit(cfg) if row[1] == "Journal"][0]
        self.assertEqual(journal[0], "WARN")
        self.assertIn("unknown", journal[2])

    def test_shell_handles_eof(self):
        with mock.patch.object(retro_ai.Companion, "cmdloop", side_effect=EOFError), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(retro_ai.cmd_shell(None), 0)

    def test_say_handles_timeout(self):
        proc = mock.Mock()
        proc.wait.side_effect = [
            subprocess.TimeoutExpired("espeak-ng", 30),
            subprocess.TimeoutExpired("espeak-ng", 2),
            0,
        ]
        with mock.patch.object(retro_ai, "load_config", return_value={"voice_speed": "150"}), \
             mock.patch.object(retro_ai, "speak", return_value=True), \
             mock.patch.object(retro_ai, "_voice_proc", proc):
            self.assertEqual(retro_ai.cmd_say(mock.Mock(text=["hello"])), 1)
        proc.terminate.assert_called_once()
        proc.kill.assert_called_once()


if __name__ == "__main__":
    unittest.main()
