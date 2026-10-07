from __future__ import annotations

import argparse
import copy
import importlib.util
import io
import json
import plistlib
import shutil
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock


RUN_PATH = Path(__file__).resolve().parents[1] / "scripts" / "run.py"
SPEC = importlib.util.spec_from_file_location("duo_piptest_run", RUN_PATH)
assert SPEC is not None and SPEC.loader is not None
run = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(run)

UDID = "11111111-2222-3333-4444-555555555555"
OTHER_UDID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
MUTATING_VERBS = {"shutdown", "boot", "install", "launch"}


class RunSafetyTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.app = self.root / "DuoPiPTest.app"
        self.app.mkdir()
        self._write_plist(self.app / "Info.plist", {"CFBundleIdentifier": run.BUNDLE_ID})

        self.source = self.root / "Duo.simdevicetype" / "Contents" / "Resources" / "capabilities.plist"
        self.source.parent.mkdir(parents=True)
        self.source_data = {
            "capabilities": {
                "PiPOverlay": False,
                "PiPPinned": False,
                "UnrelatedCapability": {"Keep": "original"},
            },
            "UnrelatedTopLevel": ["preserve", 42],
        }
        self._write_plist(self.source, self.source_data)
        self.device = {
            "udid": UDID,
            "name": "Duo Test",
            "isAvailable": True,
            "deviceTypeIdentifier": run.DEVICE_TYPE_ID,
            "state": "Booted",
        }
        self.effective = str(self.root / "different-profile.plist")
        self.calls: list[tuple[tuple[str, ...], dict[str, str] | None]] = []
        self.getenv_error = False

        patcher = mock.patch.object(run, "REPO", self.repo)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _write_plist(self, path: Path, data: dict) -> None:
        with path.open("wb") as file:
            plistlib.dump(data, file)

    def fake_simctl(self, *args: str, timeout: int = 20, env: dict[str, str] | None = None) -> str:
        self.calls.append((args, env))
        if args == ("list", "devices", "-j"):
            return json.dumps({"devices": {"test-runtime": [self.device]}})
        if args == ("list", "devicetypes", "-j"):
            return json.dumps({
                "devicetypes": [{
                    "identifier": run.DEVICE_TYPE_ID,
                    "bundlePath": str(self.source.parents[2]),
                }]
            })
        if args == ("getenv", UDID, "SIMULATOR_CAPABILITIES"):
            if self.getenv_error:
                raise run.SetupError("No effective profile is available")
            return self.effective
        if args == ("boot", UDID):
            assert env is not None
            self.effective = env["SIMCTL_CHILD_SIMULATOR_CAPABILITIES"]
            self.getenv_error = False
            return ""
        if args[0] in MUTATING_VERBS or args[0] == "bootstatus":
            return ""
        raise AssertionError(f"Unexpected simctl call: {args}")

    def run_helper(self, *, restart: bool = False, status: bool = False) -> int:
        args = argparse.Namespace(device=UDID, app=self.app, restart=restart, status=status)
        with mock.patch.object(run, "parse_args", return_value=args), \
             mock.patch.object(run, "simctl", side_effect=self.fake_simctl), \
             mock.patch.object(run.subprocess, "run", side_effect=AssertionError("Real subprocess call")), \
             redirect_stdout(io.StringIO()):
            return run.main()

    def assert_no_mutating_simctl(self) -> None:
        self.assertFalse(
            [args for args, _ in self.calls if args[0] in MUTATING_VERBS],
            self.calls,
        )
        self.assertFalse((self.repo / ".runtime").exists())

    def test_unknown_or_non_duo_target_never_mutates_simulator(self) -> None:
        for condition in ("unknown", "non-duo"):
            with self.subTest(condition=condition):
                self.calls.clear()
                if condition == "unknown":
                    self.device["udid"] = OTHER_UDID
                else:
                    self.device["udid"] = UDID
                    self.device["deviceTypeIdentifier"] = "com.example.OtherPhone"
                with self.assertRaises(run.SetupError):
                    self.run_helper()
                self.assert_no_mutating_simctl()

    def test_wrong_booted_override_needs_explicit_restart(self) -> None:
        with self.assertRaises(run.SetupError):
            self.run_helper()
        self.assert_no_mutating_simctl()

    def test_invalid_app_or_source_profile_fails_before_mutation(self) -> None:
        cases = ("missing-app", "wrong-bundle", "missing-flag", "nonboolean-flag")
        for case in cases:
            with self.subTest(case=case):
                self.calls.clear()
                self.app.mkdir(exist_ok=True)
                app_data = {"CFBundleIdentifier": run.BUNDLE_ID}
                source_data = copy.deepcopy(self.source_data)
                if case == "missing-app":
                    shutil.rmtree(self.app)
                elif case == "wrong-bundle":
                    app_data["CFBundleIdentifier"] = "com.example.Unrelated"
                elif case == "missing-flag":
                    del source_data["capabilities"]["PiPOverlay"]
                else:
                    source_data["capabilities"]["PiPPinned"] = "false"
                if self.app.exists():
                    self._write_plist(self.app / "Info.plist", app_data)
                self._write_plist(self.source, source_data)
                with self.assertRaises(run.SetupError):
                    self.run_helper(restart=True)
                self.assert_no_mutating_simctl()

    def test_status_is_read_only(self) -> None:
        for state in ("Booted", "Shutdown"):
            with self.subTest(state=state):
                self.calls.clear()
                self.device["state"] = state
                self.assertEqual(self.run_helper(status=True), 0)
                self.assert_no_mutating_simctl()

    def test_explicit_restart_changes_only_chosen_simulator_and_two_flags(self) -> None:
        self.assertEqual(self.run_helper(restart=True), 0)
        mutations = [(args, env) for args, env in self.calls if args[0] in MUTATING_VERBS]
        self.assertEqual([args[0] for args, _ in mutations], ["shutdown", "boot", "install", "launch"])
        for args, _ in mutations:
            self.assertIn(UDID, args)
            self.assertNotIn(OTHER_UDID, args)
        target = run.runtime_profile_path(UDID)
        self.assertEqual(mutations[1][1]["SIMCTL_CHILD_SIMULATOR_CAPABILITIES"], str(target))
        expected = copy.deepcopy(self.source_data)
        expected["capabilities"]["PiPOverlay"] = True
        expected["capabilities"]["PiPPinned"] = True
        self.assertEqual(run.read_plist(target), expected)
        self.assertEqual(run.read_plist(self.source), self.source_data)

    def test_explicit_restart_recovers_when_current_override_is_unreadable(self) -> None:
        self.getenv_error = True
        self.assertEqual(self.run_helper(restart=True), 0)
        mutations = [args for args, _ in self.calls if args[0] in MUTATING_VERBS]
        self.assertEqual([args[0] for args in mutations], ["shutdown", "boot", "install", "launch"])
        self.assertTrue(all(UDID in args for args in mutations))


if __name__ == "__main__":
    unittest.main()
