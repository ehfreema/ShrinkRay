# Architecture

Vid to Discord is a small SwiftUI macOS application with a single conversion service.

## Components

- `VidToDiscord/VidToDiscordApp.swift` creates the SwiftUI window.
- `VidToDiscord/ContentView.swift` contains the view and the main-actor `AppModel`. The model owns file selection, status, errors, and the current input and output URLs.
- `VidToDiscord/VideoConverter.swift` contains tool discovery, intermediate export, probing, encoding policy, process execution, output sizing, and padding.
- `project.yml` is the XcodeGen source of truth. `VidToDiscord.xcodeproj` is generated and checked in for convenience.

## Conversion flow

1. The user chooses or drops one movie. The app validates its filename extension as a macOS movie type.
2. `AppModel` starts an asynchronous conversion and displays stage messages from `VideoConverter`.
3. `VideoConverter` locates `ffmpeg` and `ffprobe` in the fixed, ordered Homebrew search paths listed in the README. Existing `ffmpeg-full` paths take precedence over standard Homebrew binary paths.
4. AVFoundation exports every source to a complete, potentially large and lossy intermediate MP4 in a unique temporary directory. The UI calls this stage tone mapping, but no explicit tone-mapping filter is configured.
5. FFprobe reads the intermediate's duration and determines whether it has an audio stream.
6. The converter estimates a total bitrate for a 7,850,000-byte target.
7. FFmpeg performs two-pass H.264 encoding. The first pass writes media to `/dev/null`; the second writes `<source-name>-discord.mp4` beside the source.
8. If the result exceeds 7,900,000 bytes, the converter recalculates bitrate and retries, for at most 12 attempts. Later attempts can force lower dimensions and frame rates.
9. If the accepted result is below 7,800,000 bytes, the converter appends an MP4 `free` atom to approach 7,850,000 bytes.
10. The output URL is returned to the UI, which can reveal it in Finder. Temporary artifacts are removed on normal scope exit.

## Encoding policy

- Video: `libx264`, two-pass, `slow` preset, Lanczos scaling, and `yuv420p`.
- Color metadata: BT.709 primaries, transfer characteristics, and colorspace.
- Audio: optional AAC stereo. Its bitrate steps down from 96 kb/s and is removed when the total bitrate is below 48 kb/s.
- Resolution and frame rate: selected from total available video bitrate, with additional emergency caps beginning on attempt 6.
- Container: MP4 with `+faststart` on the second pass.

The target, lower padding threshold, and accepted upper limit are decimal byte counts rather than MiB values.

## Data lifecycle and failure behavior

Each conversion gets a `VidToDiscord-<UUID>` temporary directory for the AVFoundation intermediate and two-pass logs. Every process invocation also gets a temporary command log. Swift `defer` blocks remove these after normal return or a thrown error, but they cannot guarantee cleanup after abnormal process termination.

The final output is not staged and atomically renamed. It is deleted before each attempt, so a failed rerun can destroy an earlier output at the same path. The source directory must be writable.

Processes are run synchronously with `Process.waitUntilExit()`. The app has no cancellation propagation or percentage-progress parser.

Because App Sandbox is disabled, FFmpeg and FFprobe run with the invoking user's filesystem permissions. The application does not otherwise isolate those subprocesses.

## Current boundaries

- macOS 15.0 and Swift 6.0
- one local input at a time
- no App Sandbox
- fixed Homebrew FFmpeg locations
- no configurable encoder, output directory, or size target
- no automated test target
- no signing, notarization, or release pipeline
