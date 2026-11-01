# Changelog

## 0.2.1 — experimental first release (2026-11-01)

- Prepare the headless background service for public review.
- Reduce idle work by relying on USB, CoreAudio, and system-power notifications when registrations succeed; retain periodic recovery only as a fallback.
- Read the current default output directly instead of enumerating every output device.
- Filter USB notifications by Bose vendor ID while preserving full IORegistry discovery for Bose mode transitions.
- Split USB discovery, CoreAudio access, routing policy, and wake observation into focused source files.
- Add bounded local control-socket and device-filter tests.
- Remove the AppKit framework dependency.

The 0.2.1 release passed detach/reconnect, user-confirmed music playback, manual output preservation, and normal-mode restoration on the same tested unit. See [validation](docs/validation.md) and [performance](docs/performance.md). No broader hardware support is claimed.

## 0.2.0 — background-service conversion

- Replace the menu-bar prototype with a headless per-user LaunchAgent.
- Add local command-line control and safe normal-mode restoration on stop.
- Confirm audible USB playback and output restoration on the single tested unit; see [docs/validation.md](docs/validation.md) for the limits of that evidence.
