import Foundation
import Testing
@testable import Vid_to_Discord

struct VideoConverterTests {
    @Test func limitsEncodingToOneCorrection() {
        #expect(VideoConverter.maxEncodingAttempts == 2)
    }

    @Test func initialBitrateUsesSafeEncodingTarget() {
        let bitrate = VideoConverter.initialTotalBitrate(duration: 60)
        #expect(bitrate == 1_010_666)
    }

    @Test func correctionAlwaysReducesBitrate() {
        let corrected = VideoConverter.correctedTotalBitrate(
            current: 1_000_000,
            fileSize: 8_000_000
        )
        #expect(corrected == 914_375)
        #expect(corrected < 1_000_000)
    }

    @Test func correctionDoesNotRetryBelowBitrateFloor() {
        let corrected = VideoConverter.correctedTotalBitrate(
            current: 1_000,
            fileSize: 8_000_000
        )
        #expect(corrected == 1_000)
    }

    @Test func encodingPlanIsChosenBeforeEncoding() {
        let plan = VideoConverter.encodingPlan(totalBitrate: 450_000, hasAudio: true)
        #expect(plan.audioBitrate == 96_000)
        #expect(plan.videoBitrate == 354_000)
        #expect(plan.maxDimension == 640)
        #expect(plan.maxFrameRate == "30")
    }

    @Test func installingNewOutputMovesStagedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "VidToDiscordTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let staged = directory.appending(path: "staged.mp4")
        let output = directory.appending(path: "output.mp4")
        try Data("new".utf8).write(to: staged)

        try VideoConverter.install(stagedOutput: staged, at: output)

        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try String(contentsOf: output, encoding: .utf8) == "new")
    }

    @Test func installingReplacementPreservesUntilPromotion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "VidToDiscordTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let staged = directory.appending(path: "staged.mp4")
        let output = directory.appending(path: "output.mp4")
        try Data("old".utf8).write(to: output)
        try Data("new".utf8).write(to: staged)
        #expect(try String(contentsOf: output, encoding: .utf8) == "old")

        try VideoConverter.install(stagedOutput: staged, at: output)

        #expect(try String(contentsOf: output, encoding: .utf8) == "new")
    }

    @Test func convertsSyntheticVideoEndToEndWhenFFmpegIsInstalled() async throws {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg"
        ]
        guard let ffmpegPath = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "VidToDiscordTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appending(path: "synthetic.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=duration=1:size=320x240:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=1000:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest", input.path
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let output = try await VideoConverter.convert(input: input) { _ in }
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(size == 7_850_000)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!files.contains { $0.hasSuffix(".part.mp4") })
    }
}
