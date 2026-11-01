# Architecture

## Process and lifecycle

The executable runs as a per-user `LaunchAgent` with the `run` argument. It has no AppKit dependency, menu bar, Dock icon, or window. A file lock prevents duplicate service instances. `start`, `stop`, `restart`, and `uninstall` are coordinated by the shell controller and LaunchAgent; the native executable handles only `run`, `status`, `normal`, `resume`, and `shutdown`.

## Event-driven idle behavior

The normal path is event driven:

- IOKit USB notifications are matched to vendor ID `05A7`, covering the device's supported normal and USB-mode product IDs.
- CoreAudio property listeners watch the device list and default output.
- IOKit system-power notifications trigger a refresh after wake.

If any required notification registration fails, the engine enables a 30-second recovery timer. When registrations succeed, there is no periodic health timer. Callback bursts are debounced before reconciliation. The USB inventory still walks the full IORegistry because the Bose device may temporarily be absent from ordinary USB enumeration while its audio interface is unpublished.

## Device and audio boundaries

`USBDevices.swift` owns Bose identity discovery and USB notifications. `AudioDevices.swift` owns CoreAudio property reads, output selection, and volume. `RoutingPolicy.swift` contains pure routing/volume rules. `SystemWakeObserver.swift` wraps IOKit's system-power registration and immediately acknowledges sleep messages that require acknowledgment.

`AudioDevices.current()` reads the default device ID and describes only that device. Full output enumeration is reserved for operations that need to find or restore a specific device. Device descriptors are read live; the bridge does not retain a global CoreAudio device cache.

Small helper executables perform guarded device requests. They require the exact supported metadata and use the existing device mode. The bridge does not flash firmware, install a kernel extension, or create a virtual audio device. macOS's built-in USB audio stack carries the audio stream.

## Local control and state

The control socket is a per-user Unix-domain socket under `~/Library/Application Support/BoseUSBBridge`, protected by the directory and socket permissions. Requests are newline-delimited JSON, capped at 4 KB, and limited to the fixed command allowlist. The server caps concurrent clients and serializes mutating operations. It does not accept shell commands, arbitrary paths, or arbitrary device requests.

Routing state, logs, and diagnostic snapshots stay in the local Application Support directory; preferences use the service's UserDefaults domain. The service has no telemetry or network client. Diagnostics are written only when their content changes and bursts are coalesced.
