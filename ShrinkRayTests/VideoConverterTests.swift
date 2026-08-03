import Foundation
import Testing
@testable import ShrinkRay

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
        let plan = VideoConverter.encodingPlan(
            totalBitrate: 450_000,
            hasAudio: true,
            sourceFrameRate: 60
        )
        #expect(plan.audioBitrate == 96_000)
        #expect(plan.videoBitrate == 354_000)
        #expect(plan.maxDimension == 640)
        #expect(plan.maxFrameRate == "30")
    }

    @Test func priorityTradesFrameRateForResolutionAtTheSameBitrate() {
        let frameRate = VideoConverter.encodingPlan(
            totalBitrate: 450_000,
            hasAudio: true,
            priority: .frameRate,
            sourceFrameRate: 120
        )
        let balanced = VideoConverter.encodingPlan(
            totalBitrate: 450_000,
            hasAudio: true,
            priority: .balanced,
            sourceFrameRate: 120
        )
        let resolution = VideoConverter.encodingPlan(
            totalBitrate: 450_000,
            hasAudio: true,
            priority: .resolution,
            sourceFrameRate: 120
        )

        #expect(frameRate.maxDimension == 480)
        #expect(frameRate.maxFrameRate == "60")
        #expect(balanced.maxDimension == 640)
        #expect(balanced.maxFrameRate == "30")
        #expect(resolution.maxDimension == 960)
        #expect(resolution.maxFrameRate == "15")
        #expect(frameRate.videoBitrate == balanced.videoBitrate)
        #expect(balanced.videoBitrate == resolution.videoBitrate)
        #expect(frameRate.audioBitrate == balanced.audioBitrate)
        #expect(balanced.audioBitrate == resolution.audioBitrate)
    }

    @Test func frameRateCapNeverUpsamplesTheSource() {
        let plan = VideoConverter.encodingPlan(
            totalBitrate: 450_000,
            hasAudio: true,
            priority: .frameRate,
            sourceFrameRate: 24
        )
        #expect(plan.maxFrameRate == nil)
    }

    @Test func parsesFFprobeFrameRates() {
        #expect(VideoConverter.parsedFrameRate("30000/1001") == 30000.0 / 1001.0)
        #expect(VideoConverter.parsedFrameRate("24") == 24)
        #expect(VideoConverter.parsedFrameRate("0/0") == nil)
    }

    @Test func detectsPQAndHLGAsHDR() {
        #expect(VideoConverter.isHDRTransfer("smpte2084"))
        #expect(VideoConverter.isHDRTransfer("arib-std-b67"))
        #expect(!VideoConverter.isHDRTransfer("bt709"))
        #expect(!VideoConverter.isHDRTransfer(nil))
    }

    @Test func usesTheBT2390StandardCurve() {
        #expect(VideoConverter.bt2390Filter.contains("tonemapping=bt.2390"))
        #expect(VideoConverter.bt2390Filter.contains("tonemapping_param=0.5"))
        #expect(VideoConverter.bt2390Filter.contains("color_trc=bt709"))
    }

    @Test func installingNewOutputMovesStagedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ShrinkRayTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
            .appending(path: "ShrinkRayTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
            .appending(path: "ShrinkRayTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appending(path: "synthetic.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=duration=1:size=320x240:rate=60",
            "-f", "lavfi", "-i", "sine=frequency=1000:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest", input.path
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let output = try await VideoConverter.convert(input: input, priority: .resolution) { _ in }
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(size == 7_850_000)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!files.contains { $0.hasSuffix(".part.mp4") })
    }

    @Test func convertsSyntheticHDRToBT709WhenBT2390IsAvailable() async throws {
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg")
        let ffprobe = URL(fileURLWithPath: "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path),
              FileManager.default.isExecutableFile(atPath: ffprobe.path),
              VideoConverter.supportsBT2390(ffmpeg: ffmpeg) else {
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ShrinkRayHDRTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appending(path: "synthetic-hdr.mp4")
        let generator = Process()
        generator.executableURL = ffmpeg
        generator.arguments = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=duration=1:size=64x64:rate=24",
            "-vf", "format=yuv420p10le", "-c:v", "libx265", "-preset", "ultrafast",
            "-x265-params", "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
            "-tag:v", "hvc1", "-an", input.path
        ]
        try generator.run()
        generator.waitUntilExit()
        #expect(generator.terminationStatus == 0)

        let output = try await VideoConverter.convert(input: input, priority: .balanced) { _ in }
        let probe = Process()
        let pipe = Pipe()
        probe.executableURL = ffprobe
        probe.arguments = [
            "-v", "error",
            "-show_entries", "stream=pix_fmt,color_primaries,color_transfer,color_space,color_range",
            "-of", "json", output.path
        ]
        probe.standardOutput = pipe
        try probe.run()
        probe.waitUntilExit()
        let metadata = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        #expect(probe.terminationStatus == 0)
        #expect(metadata.contains("\"pix_fmt\": \"yuv420p\""))
        #expect(metadata.contains("\"color_space\": \"bt709\""))
        #expect(metadata.contains("\"color_transfer\": \"bt709\""))
        #expect(metadata.contains("\"color_primaries\": \"bt709\""))
    }
}
