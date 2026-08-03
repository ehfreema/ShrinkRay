# Architecture

ShrinkRay is a small SwiftUI macOS application with a single conversion service.

## Components

- `ShrinkRay/ShrinkRayApp.swift` creates the SwiftUI window.
- `ShrinkRay/ContentView.swift` contains the view and the main-actor `AppModel`. The model owns file selection, status, errors, and the current input and output URLs.
- `ShrinkRay/VideoConverter.swift` contains tool discovery, probing, HDR detection and tone mapping, encoding policy, process execution, output sizing, and padding.
- `AppIcon.icon` contains the layered Icon Composer source compiled into the application icon by Xcode 26 or later.
- `project.yml` is the XcodeGen source of truth. `ShrinkRay.xcodeproj` is generated and checked in for convenience.

## Conversion flow

1. The user chooses or drops one movie. The app validates its filename extension as a macOS movie type.
2. `AppModel` starts an asynchronous conversion and displays stage messages from `VideoConverter`.
3. `VideoConverter` locates `ffmpeg` and `ffprobe` in the fixed, ordered Homebrew search paths listed in the README. Existing `ffmpeg-full` paths take precedence over standard Homebrew binary paths.
4. FFprobe reads the source duration, audio presence, frame rate, and transfer characteristics. PQ (`smpte2084`) and HLG (`arib-std-b67`) are treated as HDR.
5. HDR conversion is accepted only when the selected FFmpeg can execute `libplacebo` with the ITU-R BT.2390 EETF. Homebrew `ffmpeg-full` supplies the filter and MoltenVK supplies its macOS Vulkan driver. The filter converts HDR directly to limited-range BT.709 and uses the standard `0.5` knee offset. SDR sources bypass tone mapping.
6. The converter estimates a total bitrate for a conservative 7,700,000-byte encoding target. Audio, resolution, and frame rate are selected from that budget and the quality-priority setting before encoding.
7. FFmpeg performs two-pass H.264 encoding directly from the source to a unique hidden staging MP4 beside the destination. The first pass writes media to `/dev/null`; the second writes the staged file. Each attempt has a separate pass-log prefix.
8. If the result exceeds 7,900,000 bytes, the converter scales the measured bitrate toward the safe target with an additional safety factor and performs one final two-pass retry.
9. If the accepted result is below 7,800,000 bytes, the converter appends an MP4 `free` atom to the staged file to approach 7,850,000 bytes.
10. The app installs the completed staged file at `<source-name>-discord.mp4`, preserving an existing output until this point. The output URL is returned to the UI, which can reveal it in Finder.

## Encoding policy

- Video: `libx264`, two-pass, `slow` preset, Lanczos scaling, and `yuv420p`.
- Color: SDR passes through the normal encode path; PQ and HLG use libplacebo's BT.2390 EETF. Output is tagged with BT.709 primaries, transfer characteristics, and colorspace.
- Audio: optional AAC stereo. Its bitrate steps down from 96 kb/s and is removed when the total bitrate is below 48 kb/s.
- Resolution and frame rate: selected from total available video bitrate and the persisted quality-priority setting before each encode.
- Container: MP4 with `+faststart` on the second pass.

The target, lower padding threshold, and accepted upper limit are decimal byte counts rather than MiB values.

## Data lifecycle and failure behavior

Each conversion gets a `ShrinkRay-<UUID>` temporary directory for two-pass logs. Every process invocation also gets a temporary command log. Swift `defer` blocks remove these after normal return or a thrown error, but they cannot guarantee cleanup after abnormal process termination.

The encoded output is staged in the destination directory, padded and validated there, then installed only after success. Existing outputs are replaced with `FileManager.replaceItemAt`; first outputs use a same-directory move. This preserves an earlier output on normal failures and is normally atomic on local filesystems, although network and cloud-synced filesystems can provide weaker semantics. The source directory must be writable.

Processes are run synchronously with `Process.waitUntilExit()`. The app has no cancellation propagation or percentage-progress parser.

Because App Sandbox is disabled, FFmpeg and FFprobe run with the invoking user's filesystem permissions. The application does not otherwise isolate those subprocesses.

## Current boundaries

- macOS 15.0 and Swift 6.0
- one local input at a time
- no App Sandbox
- fixed Homebrew FFmpeg locations
- no configurable encoder, output directory, or size target
- automated tests for sizing math, output installation, and a conditional synthetic end-to-end conversion
- no signing, notarization, or release pipeline
