# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

No public version has been released. Local builds currently use `1.0.0` as the
planned first-release marketing version; all changes remain under `Unreleased`
until that release is published.

## [Unreleased]

### Added

- MIT license.
- Architecture, contribution, security, and conduct policies.
- Detailed documentation for setup, conversion behavior, limitations, privacy, and troubleshooting.
- Automated tests for bitrate planning, retry bounds, output installation, and a synthetic end-to-end conversion.
- Icon Composer artwork for the macOS application icon.

### Changed

- Standardized the application marketing version as `1.0.0`.
- Renamed the application and project to ShrinkRay.
- Replaced the twelve-attempt compression loop with one conservative two-pass encode and at most one measured corrective retry.
- Staged completed output beside the destination so an existing conversion remains intact until its replacement succeeds.
