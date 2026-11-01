# Research boundary

The tested speaker exposes a normal USB HID interface and an existing USB Audio Class mode. The bridge selects that existing mode, configures the interface when needed, selects the USB audio source, and lets macOS stream PCM. No firmware image is installed or modified.

## Firmware comparison

The official [Phelps index](https://downloads.bose.com/ced/phelps/index.xml) lists `1.0.20` for product `0xBC59`. The official [Phelps2 index](https://downloads.bose.com/ced/phelps2/index.xml) lists `2.0.5` for `0xBC60`. Different product IDs mean the second image is not an established upgrade for the tested unit.

An offline comparison found the following in both images:

- The same audio mode and return tokens, UAC1 descriptors, and 44.1/48 kHz stereo 16-bit PCM format.
- The same 781,116-byte CSR stack and relevant mode configuration.
- The same examined diagnostic authorization, power-state, and USB input-selection flows, allowing for relocated addresses.

The files are different overall. This is evidence of retained code paths, not a physical playback or recovery result for `2.0.5`. The runtime guard remains `minnow` / `Main 1.0.20.`. No `3.0.1` or `8.2.16` firmware image was obtained for analysis.

Downloaded image SHA-256 values:

| Image | SHA-256 |
| --- | --- |
| Phelps 1.0.20 | `8b77d8fe5d52ee64b6abfccbbddccbe369a6cfd647074e27b27e52ab6aae705f` |
| Phelps2 2.0.5 | `fdda2cf4637c8f554b899f86f1eab54bf9a656d22e6a68a070ada720ec1c318a` |

Images came from Bose's public download server. Checksums and filesystem consistency were checked; a cryptographic vendor-signature trust chain was not independently validated. Firmware images, device identifiers, recordings, and raw private investigation logs are excluded from this repository.

REA was used for static analysis of the official updater. Firmware analysis used a CSR filesystem parser and a prefix-aware XAP decoder based on Rizin. Neither tool is required by or bundled with the bridge. See [NOTICE](../NOTICE).

## Limits on claims

Successful USB enumeration and submitted PCM buffers do not prove that a speaker produced sound. User-confirmed acoustic output is recorded separately in [validation](validation.md). The existence of this mode also does not establish why Bose does not expose it as a supported consumer feature.
