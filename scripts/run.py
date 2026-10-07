#!/usr/bin/env python3
"""Boot one iPhone Duo simulator with a local PiP-capable profile and run DuoPiPTest."""

from __future__ import annotations

import argparse
import os
import plistlib
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


BUNDLE_ID = "com.example.DuoPiPTest"
DEVICE_TYPE_ID = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
FALLBACK_DEVICE_TYPE = Path(
    "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Duo.simdevicetype"
)
REPO = Path(__file__).resolve().parent.parent


class SetupError(Exception):
    pass


def simctl(*args: str, timeout: int = 20, env: dict[str, str] | None = None) -> str:
    command = ["xcrun", "simctl", *args]
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=True,
            timeout=timeout,
            env=env,
        )
    except FileNotFoundError as error:
        raise SetupError("xcrun was not found; install Xcode Command Line Tools.") from error
    except subprocess.TimeoutExpired as error:
        raise SetupError(f"Timed out after {timeout}s: {' '.join(command)}") from error
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "unknown error").strip()
        raise SetupError(f"{' '.join(command)} failed: {detail}") from error
    return result.stdout.strip()


def simctl_json(*args: str) -> dict:
    try:
        import json

        value = json.loads(simctl(*args))
    except (ValueError, TypeError) as error:
        raise SetupError(f"simctl {' '.join(args)} returned invalid JSON") from error
    if not isinstance(value, dict):
        raise SetupError(f"simctl {' '.join(args)} returned an unexpected JSON value")
    return value


def selected_device(udid: str) -> dict:
    devices = simctl_json("list", "devices", "-j").get("devices")
    if not isinstance(devices, dict):
        raise SetupError("simctl device list is missing its devices map")
    matches = [
        device
        for group in devices.values()
        if isinstance(group, list)
        for device in group
        if isinstance(device, dict) and device.get("udid") == udid
    ]
    if len(matches) != 1:
        raise SetupError(f"Simulator {udid} was not found exactly once")
    device = matches[0]
    if device.get("isAvailable") is not True:
        raise SetupError(f"Simulator {udid} is unavailable")
    if device.get("deviceTypeIdentifier") != DEVICE_TYPE_ID:
        raise SetupError(f"Simulator {udid} is not an iPhone Duo")
    if device.get("state") not in ("Booted", "Shutdown"):
        raise SetupError(f"Simulator {udid} is {device.get('state')}; wait for Booted or Shutdown")
    return device


def installed_profile() -> tuple[Path, dict]:
    device_types = simctl_json("list", "devicetypes", "-j").get("devicetypes")
    if not isinstance(device_types, list):
        raise SetupError("simctl device-type list is missing devicetypes")
    matches = [
        device_type
        for device_type in device_types
        if isinstance(device_type, dict) and device_type.get("identifier") == DEVICE_TYPE_ID
    ]
    if len(matches) != 1:
        raise SetupError("The installed iPhone Duo device type was not found exactly once")
    bundle_path = matches[0].get("bundlePath")
    if bundle_path is None:
        bundle = FALLBACK_DEVICE_TYPE
    elif isinstance(bundle_path, str) and bundle_path:
        bundle = Path(bundle_path)
    else:
        raise SetupError("Installed iPhone Duo bundlePath is invalid")
    if not bundle.is_absolute() or not bundle.is_dir():
        raise SetupError(f"Installed iPhone Duo device type is missing: {bundle}")
    source = bundle / "Contents" / "Resources" / "capabilities.plist"
    if not source.is_file():
        raise SetupError(f"Installed iPhone Duo capabilities are missing: {source}")
    data = read_plist(source)
    capabilities = data.get("capabilities")
    if not isinstance(capabilities, dict):
        raise SetupError("Installed Duo capabilities.plist has no capabilities dictionary")
    for key in ("PiPOverlay", "PiPPinned"):
        if type(capabilities.get(key)) is not bool:
            raise SetupError(f"Installed Duo capabilities.plist is missing boolean {key}; refusing to guess")
    return source, data


def read_plist(path: Path) -> dict:
    try:
        with path.open("rb") as file:
            data = plistlib.load(file)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise SetupError(f"Cannot read plist {path}: {error}") from error
    if not isinstance(data, dict):
        raise SetupError(f"Plist {path} has an unexpected root value")
    return data


def profile_flags(path: Path) -> bool:
    if not path.is_file():
        return False
    capabilities = read_plist(path).get("capabilities")
    return isinstance(capabilities, dict) and all(
        capabilities.get(key) is True for key in ("PiPOverlay", "PiPPinned")
    )


def validate_app(path: Path) -> Path:
    app = path.expanduser().resolve()
    if not app.is_dir() or not (app / "Info.plist").is_file():
        raise SetupError(f"App bundle is missing: {app}")
    identifier = read_plist(app / "Info.plist").get("CFBundleIdentifier")
    if identifier != BUNDLE_ID:
        raise SetupError(f"App bundle identifier must be {BUNDLE_ID}; found {identifier!r}")
    return app


def runtime_profile_path(udid: str) -> Path:
    return REPO / ".runtime" / udid / "capabilities.plist"


def assert_local_target(path: Path) -> None:
    root = REPO / ".runtime"
    parent = path.parent
    if root.is_symlink() or parent.is_symlink() or path.is_symlink():
        raise SetupError("The local .runtime profile path must not contain symlinks")


def write_profile(path: Path, source_data: dict) -> None:
    assert_local_target(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    capabilities = source_data["capabilities"]
    capabilities["PiPOverlay"] = True
    capabilities["PiPPinned"] = True
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".capabilities-", delete=False) as file:
            temporary_name = file.name
            plistlib.dump(source_data, file, fmt=plistlib.FMT_XML, sort_keys=False)
        os.replace(temporary_name, path)
    finally:
        if temporary_name and os.path.exists(temporary_name):
            os.unlink(temporary_name)
    if not profile_flags(path):
        raise SetupError(f"The local PiP flags were not written: {path}")


def effective_profile(udid: str) -> Path:
    value = simctl("getenv", udid, "SIMULATOR_CAPABILITIES")
    if not value:
        raise SetupError(f"Simulator {udid} has no SIMULATOR_CAPABILITIES path")
    return Path(value).resolve()


def status(udid: str, device: dict, target: Path) -> None:
    print(f"{device.get('name', 'iPhone Duo')} ({udid}): {device['state']}")
    print(f"Local PiP profile: {target} ({'ready' if profile_flags(target) else 'missing or invalid'})")
    if device["state"] == "Booted":
        actual = effective_profile(udid)
        print(f"Effective profile: {actual}")
        print(f"PiP override active: {'yes' if actual == target.resolve() and profile_flags(target) else 'no'}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run DuoPiPTest on one explicitly chosen iPhone Duo simulator."
    )
    parser.add_argument("--device", required=True, metavar="UUID", help="iPhone Duo simulator UUID")
    parser.add_argument("--app", type=Path, default=REPO / "build" / "DuoPiPTest.app", help="built app bundle")
    parser.add_argument("--restart", action="store_true", help="shut down and reboot only --device if booted")
    parser.add_argument("--status", action="store_true", help="inspect the selected simulator without changing it")
    args = parser.parse_args()
    try:
        args.device = str(uuid.UUID(args.device)).upper()
    except ValueError as error:
        parser.error("--device must be a simulator UUID")
    return args


def main() -> int:
    args = parse_args()
    udid = args.device
    device = selected_device(udid)
    target = runtime_profile_path(udid)
    assert_local_target(target)
    if args.status:
        status(udid, device, target)
        return 0

    app = validate_app(args.app)
    source, source_data = installed_profile()
    print(f"Installed Duo profile: {source}")
    print(f"Selected simulator: {device.get('name', 'iPhone Duo')} ({udid})")

    booted = device["state"] == "Booted"
    if booted and args.restart:
        print(f"Shutting down only {udid} (--restart).")
        simctl("shutdown", udid, timeout=90)
        booted = False
    elif booted:
        try:
            actual = effective_profile(udid)
        except SetupError as error:
            raise SetupError(f"{error}. Use --restart to recover this simulator.") from error
        if actual != target.resolve() or not profile_flags(target):
            raise SetupError(
                f"{udid} is already booted with {actual}. "
                "Run again with --restart to restart only this simulator with the local PiP profile."
            )
        print("Existing local PiP profile is active; keeping the simulator running.")

    if not booted:
        write_profile(target, source_data)
        env = os.environ.copy()
        env["SIMCTL_CHILD_SIMULATOR_CAPABILITIES"] = str(target)
        print(f"Booting only {udid} with {target}.")
        simctl("boot", udid, timeout=90, env=env)
        simctl("bootstatus", udid, "-b", timeout=180)

    actual = effective_profile(udid)
    if actual != target.resolve() or not profile_flags(target):
        raise SetupError(f"PiP override did not become active on {udid}; effective profile is {actual}")
    simctl("install", udid, str(app), timeout=120)
    print(simctl("launch", "--terminate-running-process", udid, BUNDLE_ID, timeout=45))
    print("Ready. Choose a video shape and tap Start PiP in the app.")
    print("To pin the native mini-player on the inner display, tap its two-rectangle control beside fullscreen.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SetupError as error:
        print(f"duo-piptest: {error}", file=sys.stderr)
        raise SystemExit(1)
