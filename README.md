# ShrinkRay

A small native macOS app that converts one local movie at a time into a Discord-sized MP4. It uses AVFoundation for an intermediate MP4 export and FFmpeg for two-pass H.264 encoding, reducing bitrate, resolution, frame rate, or audio quality when necessary.

Conversion happens locally. The app does not upload the source or output video.

## Requirements

- macOS 15.0 or later
- Xcode 26 or later with Icon Composer app-icon support and the Swift 6 toolchain to build the app
- [Homebrew](https://brew.sh/) and FFmpeg at runtime

Install FFmpeg and FFprobe with:

```sh
brew install ffmpeg
```

The FFmpeg build must include the `libx264` video encoder and the native AAC encoder. Homebrew's standard `ffmpeg` formula currently provides these. You can verify the selected Homebrew installation with:

```sh
"$(brew --prefix)/bin/ffmpeg" -hide_banner -encoders
```

Look for `libx264` and `aac` in the output.

The app does **not** search `$PATH` or allow a custom tool location. It checks for both `ffmpeg` and `ffprobe` in this order:

1. `/opt/homebrew/opt/ffmpeg-full/bin`
2. `/usr/local/opt/ffmpeg-full/bin`
3. `/opt/homebrew/bin`
4. `/usr/local/bin`

The first two entries support systems that already have an `ffmpeg-full` formula or compatible link; this project does not require or instruct you to install that formula. Installations available only through MacPorts, Nix, a shell version manager, a cask, or another directory are not detected.

## Build and run

Run these commands from the project root—the directory containing `project.yml` and `ShrinkRay.xcodeproj`.

Open the checked-in Xcode project:

```sh
open ShrinkRay.xcodeproj
```

Select the **ShrinkRay** scheme, then build and run it from Xcode.

For a command-line Debug build:

```sh
xcodebuild \
  -project ShrinkRay.xcodeproj \
  -scheme ShrinkRay \
  -configuration Debug \
  -derivedDataPath build \
  build

open "build/Build/Products/Debug/ShrinkRay.app"
```

For a local Release build, change both occurrences of `Debug` to `Release`. The project does not include distribution signing, archiving, notarization, or packaging automation. Before distributing the app, configure an Apple development team and distribution settings in Xcode and replace the local-only `com.local.ShrinkRay` bundle identifier with one controlled by that team.

### Regenerating the Xcode project

[`project.yml`](project.yml) is the source of truth for project settings. Do not make durable project-setting changes only in the generated `.xcodeproj`. The generated project is checked in for convenience.

To regenerate it, install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and run:

```sh
brew install xcodegen
xcodegen generate
```

## Usage

1. Click **Choose Video**, or drag a movie onto the window.
2. Click **Convert**.
3. Wait for the conversion to finish.
4. Click **Show in Finder** to reveal the result.

The file picker accepts movie types recognized by macOS. Dragged files are validated from their filename extension. Actual container and codec support depends on both AVFoundation and the installed FFmpeg build.

Conversion uses an indeterminate spinner and status messages rather than percentage progress. Two-pass encoding with the `slow` preset can take much longer than the source duration, particularly for long or high-resolution videos. There is currently no Cancel button, batch conversion, configurable output directory, configurable size target, or custom FFmpeg location.

## Output behavior

- **Format:** MP4 with H.264 video and, when bitrate permits, AAC stereo audio
- **Compatibility:** `yuv420p`, BT.709 color tags, and fast-start metadata
- **Name:** `<original-name>-discord.mp4`
- **Location:** beside the source video
- **Target size:** 7,850,000 bytes
- **Accepted maximum:** 7,900,000 bytes

The app normally performs one two-pass encode. It aims for 7,700,000 bytes to leave room for MP4 overhead and encoder variance. If that result still exceeds 7,900,000 bytes, it measures the actual size and allows one corrected two-pass retry at a proportionally lower bitrate. Audio, resolution, and frame rate are selected from the calculated bitrate before each encode rather than degraded through a long retry loop. At very low bitrates audio is removed.

For sources around 60 minutes or longer, the initial bitrate estimate reaches its 1 kb/s floor. Such a conversion uses approximately 96 pixels on the longest edge and 1 fps with no audio. If an output at that floor is still oversized, the app fails immediately rather than repeating an identical encode. Trim long sources before conversion if watchable output matters.

Outputs smaller than 7,800,000 bytes are normally padded to 7,850,000 bytes by appending a valid MP4 `free` atom. Padding does not add media or improve quality; it makes output size predictable.

### Existing output safety

Encoding and padding occur in a uniquely named hidden staging file beside the destination. An existing `<original-name>-discord.mp4` remains untouched until a new result succeeds and passes the size check. The app then replaces the old output in one filesystem replacement operation when the destination already exists, or moves the staged file into place on the first conversion. Local filesystems normally make this final same-directory operation atomic; network and cloud-synced filesystems may provide weaker guarantees.

### Intermediate export

Before FFmpeg runs, AVFoundation exports a complete, potentially lossy intermediate MP4 for every source. This intermediate can be large, so the macOS temporary volume may need gigabytes of free space for a long or high-resolution input; the scratch location is not configurable. The in-app **Tone mapping to SDR** stage label describes the intent, but the code does not explicitly configure a tone-mapping filter, so correct HDR-to-SDR conversion is not guaranteed. Protected media and formats AVFoundation cannot export are unsupported.

The source directory must be writable. Network, cloud-synced, removable, or read-only locations can fail while deleting or writing the final output; copy the source to a writable local directory if needed.

## Privacy and temporary files

All processing is local. During conversion, the app creates:

- a unique temporary directory containing the complete AVFoundation intermediate and FFmpeg two-pass logs; and
- a separate temporary command log for each FFmpeg or FFprobe process; and
- a uniquely named hidden staging MP4 beside the final destination.

These files are deleted after the relevant operation returns normally, whether it succeeds or throws. A crash, force-quit, power loss, or other abnormal termination can bypass cleanup and leave intermediates or logs in the macOS temporary directory or a hidden `.part.mp4` beside the source. macOS may eventually purge its temporary directory, but the app does not clean up artifacts from earlier interrupted runs.

There is no explicit process cancellation. If conversion is interrupted, the current FFmpeg process is not programmatically terminated by the conversion task.

The app runs without the macOS App Sandbox. It executes `ffmpeg` and `ffprobe` directly with the invoking user's filesystem permissions, so those subprocesses can access anything that user account can access—not only the selected video. Only use FFmpeg installations and input files you trust.

## Troubleshooting

### “FFmpeg was not found”

`which ffmpeg` only confirms that your shell can find FFmpeg; it does not confirm that the app can. Verify both executables at one of the supported locations, for example:

```sh
test -x /opt/homebrew/bin/ffmpeg && echo "ffmpeg found"
test -x /opt/homebrew/bin/ffprobe && echo "ffprobe found"
```

Use `/usr/local/bin` instead on a typical Intel Homebrew installation. If the tools are installed elsewhere, the app will not detect them.

### FFmpeg reports “Unknown encoder”

The selected FFmpeg build must provide `libx264` and AAC encoding. Check its encoders as described under [Requirements](#requirements). Remove or rename an incompatible `ffmpeg-full` installation if the app is selecting it before a working standard Homebrew installation.

### “The video duration could not be read”

This message can indicate failure during either the AVFoundation intermediate export or FFprobe inspection; it does not always mean the duration itself is invalid. Confirm that macOS can open and export the source, that `ffprobe` exists at a supported path, that the source is not DRM-protected, and that the macOS temporary volume has enough free space. Trying a different source container or codec may help.

### A dragged file is rejected

Drag-and-drop validation uses the filename extension. Use **Choose Video** or give the file an extension macOS recognizes as a movie. A recognized extension does not guarantee that AVFoundation can decode the file's actual contents.

### Conversion appears stuck

The app reports stages but not percentage progress, and two-pass `slow` encoding can take a long time. There is no in-app cancellation. If you terminate the app, check Activity Monitor for an FFmpeg process that is still running and check the macOS temporary directory for artifacts left by the interrupted conversion.

### No output appears

Look beside the source for a file ending in `-discord.mp4`, or use **Show in Finder** after a successful conversion. A failed conversion preserves a previous output with that name; see [Existing output safety](#existing-output-safety).

### The output is still too large or too low quality

The app makes one initial two-pass encode and at most one size-corrected retry. Extremely long or complex videos can still fail to fit under 7,900,000 bytes, while low calculated bitrates can produce impractically low resolution or frame rate. Trim the source and try again.

## Development

- [Architecture and conversion pipeline](ARCHITECTURE.md)
- [Contribution and manual testing guide](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md)
- App entry point: `ShrinkRay/ShrinkRayApp.swift`
- UI and app state: `ShrinkRay/ContentView.swift`
- Conversion pipeline: `ShrinkRay/VideoConverter.swift`
- Project configuration: `project.yml`

The `ShrinkRayTests` target covers bitrate planning, retry bounds, staged output installation, and an end-to-end synthetic conversion when Homebrew FFmpeg is installed. Run it with:

```sh
xcodebuild -project ShrinkRay.xcodeproj -scheme ShrinkRay -configuration Debug -derivedDataPath build test
```

## Releases

Releases use [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html), and notable changes are recorded in [`CHANGELOG.md`](CHANGELOG.md). Local builds currently carry the planned first-release marketing version `1.0.0`; no `1.0.0` release has been published yet.

## License

Copyright 2026 Ethan Freeman. Licensed under the [MIT License](LICENSE).

See [`SECURITY.md`](SECURITY.md) to report vulnerabilities privately through GitHub.
