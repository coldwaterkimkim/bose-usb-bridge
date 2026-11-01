# Resource use

The bridge controls routing and the speaker's existing mode; it does not process or relay PCM. Audio streaming is handled by macOS's native USB audio driver.

## Idle snapshots, 2026-11-01

Two release builds were sampled on the same Apple Silicon Mac running macOS 27.2, with Bose USB active and no playback. Each sampling window lasted about 60 seconds. The old process was 37 seconds old at the start; the new one was 30 seconds old. `proc_pid_rusage(RUSAGE_INFO_V4)` was read once per second from a separate process. No device or control status requests were made during the windows.

| Metric | 0.2.0 | 0.2.1 |
| --- | ---: | ---: |
| Total process CPU time during window | 1.218 ms | 0.083 ms |
| Mean physical footprint | 4.61 MB | 4.37 MB |
| Mean resident size (RSS) | 14.26 MB | 14.87 MB |
| Interrupt wakeups | 8 | 6 |
| Package-idle wakeups | 0 | 0 |
| Disk bytes written | 0 | 0 |

MB means 1,000,000 bytes. Physical footprint and resident size measure different things; the latter increased in this pair of observations. These are short idle snapshots, not a benchmark proving a percentage speedup or a universal memory reduction. CPU totals were already very small, and startup timing, memory pressure, and OS activity can affect both memory figures. Streaming, attachment, and other Macs were not profiled here.

## Concrete changes

- No periodic maintenance timer when USB, CoreAudio, and system-power registrations succeed. A failed registration enables a 30-second fallback with timing tolerance.
- Bose-filtered USB notifications and coalesced event bursts.
- Direct reads of the current audio device instead of repeated full output enumeration.
- No AppKit dependency; IOKit provides wake notifications.
- Event-based command completion, coalesced diagnostics, and no rewriting unchanged snapshots.
- At most four simultaneous local control clients, with bounded messages and waits.
- Size-optimized Swift/C builds and stripped distribution symbols.

## Reproduce a measurement

The optional source-only `Tools/resource_probe.c` is never installed by the bridge. It validates the requested process's executable path and process start time, then reads resource counters. It sends no USB requests.

```sh
clang -O2 -Wall -Wextra -Werror Tools/resource_probe.c -o /tmp/bose-usb-resource-probe
bridge_pid=$(launchctl print "gui/$(id -u)/local.codex.BoseUSBBridge" | awk '/pid =/ {print $3; exit}')
/tmp/bose-usb-resource-probe "$bridge_pid" 60 \
  "$HOME/Library/Application Support/BoseUSBBridge/Service/bin/BoseUSBBridge"
```

The CSV contains counters only. Sum user and system CPU deltas for total CPU time; divide by the measured wall time for a one-core average. Instruction/cycle counters are retained but were not used for the published summary. Do not compare runs that include different routing operations or playback conditions.
