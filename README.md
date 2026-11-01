# Bose USB Bridge

**Experimental release: 0.2.1.** Bose USB Bridge is a headless macOS service that detects a supported SoundLink Flex over USB and selects its existing USB audio mode. macOS exposes it through the built-in USB audio stack, so it can act as a wired speaker without a virtual audio device or kernel driver.

The service runs as a per-user LaunchAgent. It can select Bose as the default output when the speaker connects, and restore the previous output when it disconnects. It has no menu bar, Dock icon, or window.

[Download v0.2.1](https://github.com/coldwaterkimkim/bose-usb-bridge/releases/tag/v0.2.1) · [Apple Silicon installer ZIP](https://github.com/coldwaterkimkim/bose-usb-bridge/releases/download/v0.2.1/BoseUSBBridge-0.2.1-macos-arm64.zip)

## Scope and support

Support is deliberately narrow. The tested unit identifies itself to the guarded helper as `minnow` with firmware metadata exactly `Main 1.0.20.`. Other metadata is refused. The unit is a Bose SoundLink Flex; its generation has not been confirmed from an authoritative model label. The owner believes it is likely first generation, so this result does not establish broad first-generation support.

SoundLink Flex 2nd Gen is **not supported**. Official `2.0.5` firmware retains the same relevant USB paths in offline comparison, but has not been tested on hardware and is not an enabled target. Firmware versions `3.0.1` and `8.2.16` have not been analyzed. See [the support matrix](docs/support-matrix.md) for the verified boundary.

The project does not write or update firmware, enter a bootloader, install a kernel driver, or create a virtual audio device. It sends narrowly scoped USB/HID requests to select the device’s existing mode; macOS handles the resulting USB audio stream.

## Requirements

- macOS 14 or later
- Swift 5.9 and Xcode Command Line Tools for a source build
- Apple Silicon for the supplied build artifact; Intel has not been validated
- A data-capable USB-C cable

The packaged executable is ad-hoc signed and not notarized. Review the source and package before installing. Do not disable Gatekeeper globally or remove quarantine attributes recursively. If macOS presents a specific warning for an app or installer you have reviewed and trust, follow Apple’s [per-app security override guidance](https://support.apple.com/en-us/102445).

## Build and install from source

From the repository root:

```sh
./script/build_and_run.sh --verify
```

This builds the app and its small device helpers, packages them, installs the per-user LaunchAgent, starts the service, and checks that it reaches a settled process state. It can stop and replace an existing installation. It also refuses to proceed while the older `/Applications/Bose USB.app` is present or running; quit and remove that older controller first.

To build the package without installing or starting the service:

```sh
./script/build_and_run.sh --build-only
```

This is a local source build workflow. The source-built binary targets the current build architecture; Intel is not validated. The packaged release artifact is Apple Silicon only.

## Install a prepared binary package

Extract the release ZIP, open Terminal in its `BoseUSBBackground` folder, and run:

```sh
./install.sh
```

This installs the included Apple Silicon binaries without a compiler. The package is ad-hoc signed, not notarized; building from reviewed source is the recommended path if macOS blocks a downloaded binary. The package's `./control.sh` also accepts the commands below.

## Control the service

After installation, the controller is at:

```sh
"$HOME/Library/Application Support/BoseUSBBridge/control.sh"
```

For example:

```sh
"$HOME/Library/Application Support/BoseUSBBridge/control.sh" status
"$HOME/Library/Application Support/BoseUSBBridge/control.sh" normal
"$HOME/Library/Application Support/BoseUSBBridge/control.sh" resume
```

Commands:

- `status` prints a JSON status snapshot.
- `normal` asks the speaker to return to its ordinary USB mode and restores the output selected before Bose USB activation. The service remains running, but automatic selection is held until `resume` or a new connection flow.
- `resume` retries automatic handling and selects Bose when a supported USB device is available.
- `start` loads or kicks the user LaunchAgent.
- `stop` requests a safe shutdown, confirms normal-mode cleanup, then unloads the LaunchAgent. If cleanup or process exit cannot be confirmed, it leaves the LaunchAgent loaded.
- `restart` performs the same safe stop before starting again.
- `uninstall` safely stops the service and removes its owned LaunchAgent, service binaries, and management scripts. It preserves settings and diagnostics.

The native executable accepts `run`, `status`, `normal`, `resume`, and `shutdown`. Most users should use `control.sh`, which coordinates LaunchAgent lifecycle operations.

## Privacy and diagnostics

The installed service has no telemetry or network client. It communicates locally with CoreAudio, IOKit, the speaker, and its per-user Unix-domain control socket. Routing state, logs, and diagnostics are stored under `~/Library/Application Support/BoseUSBBridge`. Preferences use the `local.codex.BoseUSBBridge` UserDefaults domain. Uninstall preserves both.

The routing-session file contains output-device UIDs and names. Diagnostics and control-command responses can contain output names, remembered volume, and service events. Review and redact the entire Support folder and any command output before sharing. Do not post a raw diagnostics file or include serial numbers, usernames, or unrelated device details in an issue.

The helper derives a device-specific diagnostic authorization value in memory to access the existing input-selection controls. It does not log the serial or derived value. That derivation is part of the published source; no device-specific credential is bundled.

## Validation evidence

On the tested unit, USB audio playback was confirmed by the user during the 0.2.0 background-service trial. A separate earlier USB playback check was performed with Mac Bluetooth turned off; Bluetooth state was not changed during the later service trial. Physical generation, sleep/wake behavior, and Intel support remain unverified. The optimized 0.2.1 release also passed physical detach/reconnect and user-confirmed music playback on the same unit. See [validation notes](docs/validation.md) and [resource measurements](docs/performance.md); unit tests do not establish broader hardware coverage.

## Contributing

AI-assisted and “vibe-coded” contributions are welcome. Keep firmware and device identity guards intact, add pure unit tests for policy changes, and report automated-test evidence separately from physical-device evidence. See [contributor guidance](docs/contributing.md) and [architecture notes](docs/architecture.md).

## License and attribution

Project source is licensed under the MIT License. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Bose and SoundLink are trademarks of Bose Corporation; this project is independent and is not endorsed by Bose.
