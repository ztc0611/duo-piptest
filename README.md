# iPhone Duo Simulator PiP Test

A small native video player for testing Picture in Picture (PiP) layouts on the iPhone Duo simulator. Useful to test app behavior when pinning PiP on the inner screen in portrait. Currently the simulator has PiP disabled, this project has instructions both to re-enable it, and a test project for different aspect ratios.

<img width="8000" height="2965" alt="Four iPhone Duos showing a pinned Picture in Picture video above the active app at 21:9, 16:9, 4:3 and 1:1. Wider videos fill the full width and leave the app more room (about 69% and 59% of the screen height). 4:3 and 1:1 both stop at about half the screen height, leaving the app about 49%, and 1:1 shows black bars on the sides." src="https://github.com/user-attachments/assets/166e5605-7978-4040-9deb-3069d1d20737" />

## Tested setup

- Apple Silicon Mac
- Xcode 27.1 RC (`27A9275`)
- iOS 27.1 simulator runtime (`24A94232`)

Other versions and devices have not been verified.

## Enable PiP on the Duo simulator

In the tested runtime, the stock iPhone Duo simulator profile has `capabilities.PiPOverlay` and `capabilities.PiPPinned` set to false. Installing the test app alone does **not** enable native PiP. The override must be present **when that simulator boots**; setting an environment variable when launching the app is too late. Use a dedicated Duo simulator so restarting it does not close work in another device.

### Recommended: use the setup helper

Prerequisites: Python 3 (standard library only) and the Xcode 27.1 developer directory selected with its iOS simulator SDK available. Build the app:

```sh
./scripts/build.sh
```

Create a dedicated iPhone Duo in Xcode's Device Hub, keep it in the closed/cover pose for boot, and find its UUID with `xcrun simctl list devices available`. Check that the UUID belongs to **iPhone Duo**, then run from this repository:

```sh
python3 scripts/run.py --device YOUR_DUO_UUID --restart
python3 scripts/run.py --device YOUR_DUO_UUID --status
```

Use your actual UUID in place of `YOUR_DUO_UUID`. `--status` should report **PiP override active: yes**. `--restart` shuts down **only** the named Duo and closes its running apps. The helper refuses to restart an already running simulator without that explicit option; if the chosen Duo is shut down, `--restart` is harmless. It validates the device and app, copies the installed Duo capabilities into the ignored `.runtime/YOUR_DUO_UUID/` directory, changes only the two PiP flags, boots with the copy, verifies the effective path, then installs and launches the app. It never edits the Apple-installed profile. Keep this checkout and its `.runtime/` copy in place until that simulator shuts down.

### Manual: enable the capabilities without this app

The same boot override can be used with another PiP-capable app. First find a **dedicated iPhone Duo** in `xcrun simctl list devices available` and verify its UUID. Close the Duo to its cover pose **before** running the commands. From this repository's root, run them with that UUID substituted:

```sh
(
  set -e
  DUO_UDID=YOUR_DUO_UUID
  DUO_PROFILE='/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone Duo.simdevicetype/Contents/Resources/capabilities.plist'
  PIP_CAPABILITIES="$PWD/.runtime/$DUO_UDID/capabilities.plist"

  if [ ! -f "$DUO_PROFILE" ]; then
    echo 'Installed Duo profile not found; use scripts/run.py to resolve it' >&2
    exit 1
  fi
  # Close the Duo to its cover pose first. Shut down only this UUID if it is running.
  if xcrun simctl list devices booted | grep -Fq "$DUO_UDID"; then
    xcrun simctl shutdown "$DUO_UDID"
  fi
  mkdir -p "$(dirname "$PIP_CAPABILITIES")"
  cp "$DUO_PROFILE" "$PIP_CAPABILITIES"
  plutil -replace capabilities.PiPOverlay -bool YES "$PIP_CAPABILITIES"
  plutil -replace capabilities.PiPPinned -bool YES "$PIP_CAPABILITIES"

  SIMCTL_CHILD_SIMULATOR_CAPABILITIES="$PIP_CAPABILITIES" xcrun simctl boot "$DUO_UDID"
  xcrun simctl bootstatus "$DUO_UDID" -b
  test "$(xcrun simctl getenv "$DUO_UDID" SIMULATOR_CAPABILITIES)" = "$PIP_CAPABILITIES"
  echo "PiP override active: $PIP_CAPABILITIES"
)
```

The final `test` requires `getenv` to exactly match the absolute local path and stops on a mismatch. This changes only a local copy; do not edit the Apple-installed plist, substitute an iPad profile, or commit or redistribute the copy. If that exact installed path does not exist, use `scripts/run.py`, which resolves the current Duo device-type bundle from CoreSimulator metadata. A normal reboot without the boot override returns to stock capabilities; repeat these steps after a reboot or SpringBoard crash if PiP stops working. The app's bundle identifier is `com.example.DuoPiPTest`.

## Try PiP

1. Launch Duo PiP Test.
2. Choose an aspect ratio: `21:9`, `16:9`, `4:3`, `1:1`, or `9:16`.
3. Tap **Start PiP**. Starting PiP is explicit in this test app; pressing Home does not start it automatically.
4. Unfold the Duo to its inner display, then tap the floating video to show its controls.
5. Tap the **two-rectangles** control beside Fullscreen to pin the video to the upper display. The lower display can then show another app. Going into partially folded mode makes the video go 50/50 regardless of aspect ratio.

Stop PiP before changing the aspect ratio. The test app’s ratio and Start/Stop controls stay at the bottom.

## Checks

Run the unit tests with:

```sh
python3 -m unittest discover -s Tests -v
```

These tests mock simulator commands and verify device targeting and restart guards.

## Compatibility

This workflow depends on a private simulator capabilities override for PiP overlay and pinning. It is experimental, has only been tested with the Xcode and iOS versions listed above, and is not a distributable Apple profile or shipping entitlement.

The simulator capability override follows the approach described in [Mocking Capabilities in the iOS Simulator](https://saagarjha.com/blog/2019/01/11/mocking-capabilities-in-the-ios-simulator/). For Duo design guidance, see Apple’s [Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/).

The included video sources are procedurally generated gradients at their intended dimensions.
