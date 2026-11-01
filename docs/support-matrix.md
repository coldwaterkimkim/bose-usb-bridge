# Support matrix

The bridge refuses to change USB modes unless the connected Bose device matches its narrow identity and firmware guards. A successful build or unit test does not expand this matrix.

| Device / firmware | Status | Evidence |
| --- | --- | --- |
| Bose SoundLink Flex reporting `minnow` / `Main 1.0.20.` | Tested target | USB mode transition and audible USB playback were confirmed on the attached unit. |
| SoundLink Flex generation of that unit | Unconfirmed | The owner believes it is likely first generation, but the exact generation was not confirmed from an authoritative model label. |
| SoundLink Flex 2nd Gen | Unsupported | No verified compatible firmware or device behavior. |
| `2.0.5` firmware for product ID `0xBC60` | Unsupported | Official firmware was downloaded; USB mode, descriptors, and relevant control paths were retained. Actual playback on this version remains untested. The helper's exact `Main 1.0.20.` guard rejects it. |
| Firmware `3.0.1` and `8.2.16` | Not checked | No hardware validation. |
| Intel Macs | Not validated | The packaged binary is Apple Silicon only; no Intel system test is recorded. |
| macOS sleep/wake, logout/login lifecycle | Not validated | Event registration and fallback code are present, but no physical lifecycle result is claimed here. |

Unknown model names, generations, transports, product IDs, and firmware versions should be treated as unsupported. Do not relax the helper guards to “try” an unverified device.
