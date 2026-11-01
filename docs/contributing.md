# Contributing

AI-assisted and vibe-coded contributions are welcome. Keep changes small, explain the behavior they affect, and separate test output from physical-device observations.

## Safety and review

- Preserve the device identity and exact firmware guards. Unknown hardware must remain refused.
- Do not add firmware images, firmware-write paths, arbitrary HID commands, driver detachment, or kernel extensions.
- Keep tests for routing and device-selection rules pure; tests must not start the service or invoke the device helpers.
- Do not include serials, personal output-device names, usernames, private logs, recordings, or firmware files in commits or issues.
- A code review, a successful build, or an AI agent's summary is not physical-device evidence. State which checks ran and which hardware conditions were actually observed.

## Local development

Requirements are macOS 14+, Swift 5.9, and Xcode Command Line Tools. Useful commands from the repository root:

```sh
swift test
./script/build_and_run.sh --build-only
```

`--build-only` creates a local package without installing or starting the LaunchAgent. `--verify` installs and starts the per-user service; it changes the current user's LaunchAgent state and can change the Mac's default audio output when supported hardware is connected.

Do not publish, tag, or distribute a candidate until its code and test results have been reviewed and its supported-device claims match the validation evidence.
