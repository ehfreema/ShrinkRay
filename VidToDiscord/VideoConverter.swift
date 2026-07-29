import AVFoundation
import Foundation

enum ConversionError: LocalizedError {
    case ffmpegMissing
    case invalidVideo
    case commandFailed(String)
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            "FFmpeg was not found. Install it with: brew install ffmpeg"
        case .invalidVideo:
            "The video duration could not be read."
        case .commandFailed(let message):
            message.isEmpty ? "FFmpeg could not convert this video." : message
        case .outputTooLarge:
            "FFmpeg could not produce a valid Discord-sized video."
        }
    }
}

enum VideoConverter {
    private static let lowBytes: Int64 = 7_800_000
    private static let highBytes: Int64 = 7_900_000
    private static let targetBytes: Int64 = 7_850_000
    private struct EncodingPlan {
        let totalBitrate: Int
        let videoBitrate: Int
        let audioBitrate: Int
        let maxDimension: Int
        let maxFrameRate: String?
    }

    static func convert(
        input: URL,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let ffmpeg = try executable(named: "ffmpeg")
        let ffprobe = try executable(named: "ffprobe")
        let output = input.deletingLastPathComponent().appending(
            path: "\(input.deletingPathExtension().lastPathComponent)-discord.mp4"
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "VidToDiscord-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sdrInput = temporaryDirectory.appending(path: "tone-mapped.mp4")
        status("Tone mapping to SDR...")
        try await toneMap(input: input, output: sdrInput)

        status("Reading video details...")
        let info = try probe(ffprobe: ffprobe, input: sdrInput)
        // Start from the bitrate that should fill the target. If that is not enough
        // for normal quality, progressively trade audio, resolution, and frame rate
        // instead of rejecting the clip or getting stuck at a bitrate floor.
        var totalBitrate = max(1_000, Int(Double(targetBytes * 8) / info.duration) - 16_000)

        let passlog = temporaryDirectory.appending(path: "pass").path
        var size: Int64 = 0
        for attempt in 1...12 {
            let plan = encodingPlan(
                totalBitrate: totalBitrate,
                hasAudio: info.hasAudio,
                attempt: attempt
            )
            status(attempt == 1 ? "Encoding for Discord..." : "Compressing further (attempt \(attempt))...")
            try? FileManager.default.removeItem(at: output)
            try encode(
                ffmpeg: ffmpeg,
                input: sdrInput,
                output: output,
                passlog: passlog,
                plan: plan
            )
            size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
            if size <= highBytes { break }

            let corrected = Int(Double(plan.totalBitrate) * Double(targetBytes) / Double(size) * 0.95)
            totalBitrate = max(1_000, min(plan.totalBitrate - 1, corrected))
        }

        guard size <= highBytes else {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.outputTooLarge
        }
        if size < lowBytes {
            try pad(output: output, byteCount: targetBytes - size)
        }
        return output
    }

    private static func toneMap(input: URL, output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ConversionError.invalidVideo
        }
        try await session.export(to: output, as: .mp4)
    }

    private static func executable(named name: String) throws -> URL {
        let candidates = [
            "/opt/homebrew/opt/ffmpeg-full/bin/\(name)",
            "/usr/local/opt/ffmpeg-full/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)"
        ]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw ConversionError.ffmpegMissing
        }
        return URL(fileURLWithPath: path)
    }

    private static func probe(ffprobe: URL, input: URL) throws -> (duration: Double, hasAudio: Bool) {
        let output = try run(
            ffprobe,
            ["-v", "error", "-show_entries", "format=duration", "-show_entries", "stream=codec_type", "-of", "json", input.path],
            captureOutput: true
        )
        guard let data = output.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = json["format"] as? [String: Any],
              let durationText = format["duration"] as? String,
              let duration = Double(durationText), duration > 0 else {
            throw ConversionError.invalidVideo
        }
        let streams = json["streams"] as? [[String: Any]] ?? []
        return (duration, streams.contains { $0["codec_type"] as? String == "audio" })
    }

    private static func encode(
        ffmpeg: URL,
        input: URL,
        output: URL,
        passlog: String,
        plan: EncodingPlan
    ) throws {
        var filters: [String] = []
        if let maxFrameRate = plan.maxFrameRate {
            filters.append("fps=\(maxFrameRate)")
        }
        filters.append("scale=w='if(gte(iw,ih),min(\(plan.maxDimension),iw),-2)':h='if(gte(iw,ih),-2,min(\(plan.maxDimension),ih))':flags=lanczos")
        filters.append("format=yuv420p")

        let videoArguments = [
            "-y", "-hide_banner", "-loglevel", "warning", "-i", input.path,
            "-map", "0:v:0", "-vf", filters.joined(separator: ","),
            "-c:v", "libx264", "-preset", "slow", "-b:v", "\(plan.videoBitrate)",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"
        ]
        try run(ffmpeg, videoArguments + ["-pass", "1", "-passlogfile", passlog, "-an", "-f", "mp4", "/dev/null"])

        var secondPass = videoArguments + ["-pass", "2", "-passlogfile", passlog]
        if plan.audioBitrate > 0 {
            secondPass += ["-map", "0:a:0?", "-c:a", "aac", "-b:a", "\(plan.audioBitrate)", "-ac", "2"]
        } else {
            secondPass += ["-an"]
        }
        secondPass += ["-movflags", "+faststart", output.path]
        try run(ffmpeg, secondPass)
    }

    private static func encodingPlan(totalBitrate: Int, hasAudio: Bool, attempt: Int) -> EncodingPlan {
        let audioBitrate: Int
        if !hasAudio || totalBitrate < 48_000 {
            audioBitrate = 0
        } else if totalBitrate < 90_000 {
            audioBitrate = 16_000
        } else if totalBitrate < 180_000 {
            audioBitrate = 32_000
        } else if totalBitrate < 400_000 {
            audioBitrate = 64_000
        } else {
            audioBitrate = 96_000
        }

        let videoBitrate = max(1_000, totalBitrate - audioBitrate)
        var quality: (dimension: Int, frameRate: String?)
        switch videoBitrate {
        case 1_600_000...: quality = (1920, nil)
        case 800_000...: quality = (1280, nil)
        case 400_000...: quality = (960, "30")
        case 200_000...: quality = (640, "30")
        case 100_000...: quality = (480, "24")
        case 50_000...: quality = (360, "15")
        case 25_000...: quality = (256, "10")
        case 10_000...: quality = (192, "5")
        case 4_000...: quality = (128, "2")
        case 1_000...: quality = (96, "1")
        default: quality = (64, "1/5")
        }

        // Container and per-frame overhead can dominate at extremely low rates.
        // These last-resort profiles keep reducing that overhead rather than
        // repeating the same encode and eventually giving up.
        switch attempt {
        case 12...: quality = (min(quality.dimension, 32), "1/60")
        case 10...: quality = (min(quality.dimension, 64), "1/10")
        case 8...: quality = (min(quality.dimension, 96), "1")
        case 6...: quality = (min(quality.dimension, 256), "10")
        default: break
        }

        return EncodingPlan(
            totalBitrate: totalBitrate,
            videoBitrate: videoBitrate,
            audioBitrate: audioBitrate,
            maxDimension: quality.dimension,
            maxFrameRate: quality.frameRate
        )
    }

    @discardableResult
    private static func run(_ executable: URL, _ arguments: [String], captureOutput: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        let logURL = FileManager.default.temporaryDirectory.appending(path: "VidToDiscord-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer {
            try? log.close()
            try? FileManager.default.removeItem(at: logURL)
        }
        process.standardOutput = captureOutput ? pipe : log
        process.standardError = log
        try process.run()
        process.waitUntilExit()
        let output = captureOutput ? String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" : ""
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw ConversionError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func pad(output: URL, byteCount: Int64) throws {
        guard byteCount >= 8, byteCount <= Int64(UInt32.max) else { return }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var atomSize = UInt32(byteCount).bigEndian
        try withUnsafeBytes(of: &atomSize) { try handle.write(contentsOf: $0) }
        try handle.write(contentsOf: Data("free".utf8))
        try handle.write(contentsOf: Data(count: Int(byteCount - 8)))
    }
}
