# Contributing

## Setup

1. Install Xcode 16 or later, Homebrew, FFmpeg, and FFprobe as described in the README.
2. Open `VidToDiscord.xcodeproj`, or build from the project root with the documented `xcodebuild` command.
3. If project settings or target structure change, edit `project.yml` and regenerate the project with XcodeGen. Do not treat manual changes to the generated `.xcodeproj` as the source of truth.

## Scope and style

- Keep UI state and AppKit/SwiftUI interaction on the main actor.
- Keep conversion policy and external-process handling in `VideoConverter.swift` unless a change justifies splitting that service.
- Preserve useful user-facing errors; do not expose command lines containing private file paths unless necessary for troubleshooting.
- Document changes to supported paths, codecs, size thresholds, overwrite behavior, temporary files, or fallback quality in the README and architecture guide.

## Validation

There is no automated test target yet. Before sharing a change, build both configurations:

```sh
xcodebuild -project VidToDiscord.xcodeproj -scheme VidToDiscord -configuration Debug -derivedDataPath build build
xcodebuild -project VidToDiscord.xcodeproj -scheme VidToDiscord -configuration Release -derivedDataPath build build
```

Manually test at least:

- picker selection and drag-and-drop;
- a source with audio and one without audio;
- a short source that triggers padding;
- a source that requires more than one size attempt;
- a source around 62 minutes or longer to exercise the minimum-bitrate profile;
- missing FFmpeg or FFprobe;
- an FFmpeg build without `libx264`, if practical;
- an FFmpeg failure that exits nonzero, confirming that command failures are not retried;
- invalid, unsupported, and protected inputs;
- replacement of an existing output;
- a source in a read-only directory;
- low free space on the macOS temporary volume;
- output-size and very-low-quality fallback behavior; and
- interruption during intermediate export and FFmpeg encoding.

Confirm successful outputs are playable, no larger than 7,900,000 bytes, named correctly, and written beside the source. Check the macOS temporary directory when testing cleanup and interruption behavior. Interruption currently means terminating the app; afterward, check Activity Monitor for an FFmpeg process that is still running and terminate it manually if necessary.

## Submitting changes

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

After the GitHub repository is published:

1. Search existing issues before opening a new one.
2. Use an issue to discuss significant features, behavior changes, or architectural work before implementation.
3. Create a focused branch and pull request.
4. Explain user-visible behavior, manual validation, and known limitations in the pull request.
5. Include README, architecture, and changelog updates with behavior changes.

Small fixes may go directly to a focused pull request. Do not report vulnerabilities or sensitive conduct incidents in public issues; follow [SECURITY.md](SECURITY.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

Before the repository is published, coordinate proposed changes directly with Ethan Freeman through the private channel used to receive the project.

## Versioning and changelog

Use [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). Add user-visible changes under `Unreleased` in `CHANGELOG.md`; maintainers move those entries into a dated version section when publishing a release.

This project is available under the [MIT License](LICENSE).
