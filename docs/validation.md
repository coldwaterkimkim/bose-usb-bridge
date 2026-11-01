# Validation notes

These notes separate physical-device results from code-level checks. A test of routing policy or the local control socket does not establish that sound is audible on an arbitrary Bose model.

## Physical-device evidence

The recorded 0.2.0 background-service trial used the attached SoundLink Flex unit, whose generation was not authoritatively confirmed. The user confirmed audible USB playback during a 25-second music trial. In that trial, Bluetooth state was not changed. A separate earlier USB playback check was performed with Mac Bluetooth turned off; it is separate evidence and does not imply that the later service trial disabled Bluetooth.

The 0.2.0 service trial also confirmed restoration of the prior Mac output after USB disconnect and Bose USB selection after reconnect. The tested unit's guarded firmware metadata was `minnow` / `Main 1.0.20.`. These observations apply to that unit and software build only.

There is no recorded physical validation here for SoundLink Flex 2nd Gen, firmware 3.0.1 or 8.2.16, Intel Macs, or a full logout/login or sleep/wake cycle. The 0.2.1 checks below apply only to the same unit.

## Automated checks

Run the repository test suite from the project root:

```sh
swift test
```

The tests cover routing and device-selection logic, diagnostics, bounded local control-socket behavior, and read-only USB notification registration. They do not start the service, open a speaker, invoke a device helper, or test audible output. Record the exact command and result for each release candidate; update this page with new evidence before tagging a release.

## Reporting a hardware result

For a useful reproducible report, record the exact model label if available, firmware metadata reported by the device, macOS version, Mac architecture, whether Bluetooth was enabled, the USB connection state, and whether playback was actually audible. Never include serial numbers or unredacted diagnostics.

## 0.2.1 local acceptance — 2026-11-01

- Release build installed and started on the same Apple Silicon test Mac.
- The prepared binary package was uninstalled and reinstalled successfully; the stored speaker volume survived, and the service returned to active Bose USB output.
- Required USB, CoreAudio, and power notification registrations succeeded; the periodic fallback timer was disabled.
- Actual cable removal restored the prior output. Reconnection without pressing the speaker button selected Bose USB and restored the saved volume.
- A 12-second music sample was played through the automatically selected output. The user confirmed normal audible playback from the Bose speaker. Bluetooth state was not changed during this trial; the earlier Bluetooth-off trial remains separate evidence.
- A manual alternate output selection stayed selected. Explicit resume selected Bose again. Normal-mode restoration and subsequent resume completed successfully.
- Debug tests passed before the final notification-lifetime test was added; the final size-optimized suite has 16 passing tests. It includes actual read-only notification registration and stop, so these tests do not require a speaker but do call host notification APIs.
- The first optimized live build exposed a temporary Core Foundation object lifetime error at USB notification registration. That build was stopped, the lifetime was fixed, and the corrected release completed the checks above. A release-mode regression test now covers this path.
- A concurrent-client regression test exposed a double close of a socket descriptor. Ownership was corrected and repeated focused runs passed before the full suite.

See [resource measurements](performance.md). No logout/login, actual system sleep/wake, second speaker, other firmware, Intel, or older macOS hardware test was performed. macOS 14 is the build deployment target; the live host was macOS 27.2. Remote build and test results are available in [GitHub Actions](https://github.com/coldwaterkimkim/bose-usb-bridge/actions/workflows/check.yml). The local measurements and device observations above are separate from CI results.
