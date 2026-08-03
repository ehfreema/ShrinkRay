import Foundation

enum QualityPriority: Int, CaseIterable, Sendable {
    case frameRate
    case balanced
    case resolution

    var label: String {
        switch self {
        case .frameRate: "Frame Rate"
        case .balanced: "Balanced"
        case .resolution: "Resolution"
        }
    }
}

enum ConversionError: LocalizedError {
    case ffmpegMissing
    case invalidVideo
    case commandFailed(String)
    case outputTooLarge
    case bt2390Unavailable

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
        case .bt2390Unavailable:
            "HDR conversion requires FFmpeg with libplacebo and a Vulkan driver. Install them with: brew install ffmpeg-full molten-vk"
        }
    }
}

enum VideoConverter {
    private static let lowBytes: Int64 = 7_800_000
    private static let highBytes: Int64 = 7_900_000
    private static let targetBytes: Int64 = 7_850_000
    private static let encodingTargetBytes: Int64 = 7_700_000
    private static let minimumOutputBytes: Int64 = 1_024
    static let maxEncodingAttempts = 2

    struct EncodingPlan {
        let totalBitrate: Int
        let videoBitrate: Int
        let audioBitrate: Int
        let maxDimension: Int
        let maxFrameRate: String?
    }

    private struct VideoInfo {
        let duration: Double
        let hasAudio: Bool
        let frameRate: Double?
        let isHDR: Bool
    }

    private struct QualityProfile {
        let maxDimension: Int
        let maxFrameRate: String?
    }

    static func convert(
        input: URL,
        priority: QualityPriority = .balanced,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let ffmpeg = try executable(named: "ffmpeg")
        let ffprobe = try executable(named: "ffprobe")
        let output = input.deletingLastPathComponent().appending(
            path: "\(input.deletingPathExtension().lastPathComponent)-discord.mp4"
        )
        let stagedOutput = input.deletingLastPathComponent().appending(
            path: ".\(input.deletingPathExtension().lastPathComponent)-discord-\(UUID().uuidString).part.mp4"
        )
        defer { try? FileManager.default.removeItem(at: stagedOutput) }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "ShrinkRay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        status("Reading video details...")
        let info = try probe(ffprobe: ffprobe, input: input)
        if info.isHDR {
            status("Checking BT.2390 tone mapping...")
            guard supportsBT2390(ffmpeg: ffmpeg) else {
                throw ConversionError.bt2390Unavailable
            }
        }
        // Aim below the hard limit so the first two-pass encode normally fits.
        // The reserve covers muxing and rate-control variance; one measured
        // correction is available for unusual files.
        var totalBitrate = initialTotalBitrate(duration: info.duration)

        var size: Int64 = 0
        for attempt in 1...maxEncodingAttempts {
            let plan = encodingPlan(
                totalBitrate: totalBitrate,
                hasAudio: info.hasAudio,
                priority: priority,
                sourceFrameRate: info.frameRate
            )
            let passlog = temporaryDirectory.appending(path: "pass-\(attempt)").path
            if attempt == 1 {
                status(info.isHDR ? "Tone mapping HDR with BT.2390..." : "Encoding for Discord...")
            } else {
                status("Fine-tuning the file size...")
            }
            try? FileManager.default.removeItem(at: stagedOutput)
            try encode(
                ffmpeg: ffmpeg,
                input: input,
                output: stagedOutput,
                passlog: passlog,
                plan: plan,
                toneMapHDR: info.isHDR
            )
            size = try stagedOutput.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
            guard size >= minimumOutputBytes else {
                throw ConversionError.commandFailed("FFmpeg produced an invalid empty output.")
            }
            if size <= highBytes { break }

            let corrected = correctedTotalBitrate(current: plan.totalBitrate, fileSize: size)
            guard corrected < plan.totalBitrate else {
                throw ConversionError.outputTooLarge
            }
            totalBitrate = corrected
        }

        guard size <= highBytes else {
            throw ConversionError.outputTooLarge
        }
        if size < lowBytes {
            try pad(output: stagedOutput, byteCount: targetBytes - size)
        }
        try install(stagedOutput: stagedOutput, at: output)
        return output
    }

    static func initialTotalBitrate(duration: Double) -> Int {
        max(1_000, Int(Double(encodingTargetBytes * 8) / duration) - 16_000)
    }

    static func correctedTotalBitrate(current: Int, fileSize: Int64) -> Int {
        guard fileSize > 0 else { return current }
        let corrected = Int(Double(current) * Double(encodingTargetBytes) / Double(fileSize) * 0.95)
        return max(1_000, min(current - 1, corrected))
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

    private static func probe(ffprobe: URL, input: URL) throws -> VideoInfo {
        let output = try run(
            ffprobe,
            [
                "-v", "error",
                "-show_entries", "format=duration:stream=codec_type,avg_frame_rate,r_frame_rate,color_transfer",
                "-of", "json",
                input.path
            ],
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
        let videoStream = streams.first { $0["codec_type"] as? String == "video" }
        let frameRate = parsedFrameRate(videoStream?["avg_frame_rate"] as? String)
            ?? parsedFrameRate(videoStream?["r_frame_rate"] as? String)
        let colorTransfer = videoStream?["color_transfer"] as? String
        return VideoInfo(
            duration: duration,
            hasAudio: streams.contains { $0["codec_type"] as? String == "audio" },
            frameRate: frameRate,
            isHDR: isHDRTransfer(colorTransfer)
        )
    }

    private static func encode(
        ffmpeg: URL,
        input: URL,
        output: URL,
        passlog: String,
        plan: EncodingPlan,
        toneMapHDR: Bool
    ) throws {
        var filters: [String] = []
        if toneMapHDR {
            filters.append(bt2390Filter)
        }
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

    static func encodingPlan(
        totalBitrate: Int,
        hasAudio: Bool,
        priority: QualityPriority = .balanced,
        sourceFrameRate: Double? = nil
    ) -> EncodingPlan {
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
        let tier: Int
        switch videoBitrate {
        case 1_600_000...: tier = 10
        case 800_000...: tier = 9
        case 400_000...: tier = 8
        case 200_000...: tier = 7
        case 100_000...: tier = 6
        case 50_000...: tier = 5
        case 25_000...: tier = 4
        case 10_000...: tier = 3
        case 4_000...: tier = 2
        case 1_000...: tier = 1
        default: tier = 0
        }
        let quality = qualityProfile(tier: tier, priority: priority)
        let maxFrameRate = effectiveFrameRate(
            maximum: quality.maxFrameRate,
            sourceFrameRate: sourceFrameRate
        )

        return EncodingPlan(
            totalBitrate: totalBitrate,
            videoBitrate: videoBitrate,
            audioBitrate: audioBitrate,
            maxDimension: quality.maxDimension,
            maxFrameRate: maxFrameRate
        )
    }

    private static func qualityProfile(tier: Int, priority: QualityPriority) -> QualityProfile {
        let balanced = [
            QualityProfile(maxDimension: 64, maxFrameRate: "1/5"),
            QualityProfile(maxDimension: 96, maxFrameRate: "1"),
            QualityProfile(maxDimension: 128, maxFrameRate: "2"),
            QualityProfile(maxDimension: 192, maxFrameRate: "5"),
            QualityProfile(maxDimension: 256, maxFrameRate: "10"),
            QualityProfile(maxDimension: 360, maxFrameRate: "15"),
            QualityProfile(maxDimension: 480, maxFrameRate: "24"),
            QualityProfile(maxDimension: 640, maxFrameRate: "30"),
            QualityProfile(maxDimension: 960, maxFrameRate: "30"),
            QualityProfile(maxDimension: 1280, maxFrameRate: nil),
            QualityProfile(maxDimension: 1920, maxFrameRate: nil)
        ]
        let safeTier = min(max(tier, 0), balanced.count - 1)

        switch priority {
        case .balanced:
            return balanced[safeTier]
        case .frameRate:
            let frameRateCaps: [String?] = ["1", "2", "5", "10", "20", "30", "60", "60", nil, nil, nil]
            return QualityProfile(
                maxDimension: balanced[max(0, safeTier - 1)].maxDimension,
                maxFrameRate: frameRateCaps[safeTier]
            )
        case .resolution:
            let frameRateCaps: [String?] = ["1/5", "1/2", "1", "2", "5", "10", "12", "15", "15", "30", "30"]
            return QualityProfile(
                maxDimension: balanced[min(balanced.count - 1, safeTier + 1)].maxDimension,
                maxFrameRate: frameRateCaps[safeTier]
            )
        }
    }

    private static func effectiveFrameRate(maximum: String?, sourceFrameRate: Double?) -> String? {
        guard let maximum,
              let maximumValue = parsedFrameRate(maximum),
              let sourceFrameRate,
              sourceFrameRate > maximumValue + 0.01 else {
            return nil
        }
        return maximum
    }

    static func parsedFrameRate(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        let frameRate: Double?
        if components.count == 2,
           let numerator = Double(components[0]),
           let denominator = Double(components[1]),
           denominator != 0 {
            frameRate = numerator / denominator
        } else {
            frameRate = Double(value)
        }
        guard let frameRate, frameRate.isFinite, frameRate > 0 else { return nil }
        return frameRate
    }

    static func isHDRTransfer(_ value: String?) -> Bool {
        value == "smpte2084" || value == "arib-std-b67"
    }

    static let bt2390Filter = "libplacebo=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:tonemapping=bt.2390:tonemapping_param=0.5"

    static func supportsBT2390(ffmpeg: URL) -> Bool {
        do {
            try run(
                ffmpeg,
                [
                    "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "color=c=black:s=16x16:d=0.04",
                    "-vf", bt2390Filter,
                    "-frames:v", "1", "-f", "null", "-"
                ]
            )
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private static func run(_ executable: URL, _ arguments: [String], captureOutput: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        let logURL = FileManager.default.temporaryDirectory.appending(path: "ShrinkRay-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: logURL) }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
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
        let zeroes = Data(count: 256 * 1_024)
        var remaining = byteCount - 8
        while remaining > 0 {
            let count = min(Int64(zeroes.count), remaining)
            try handle.write(contentsOf: zeroes.prefix(Int(count)))
            remaining -= count
        }
    }

    static func install(stagedOutput: URL, at output: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: output.path) {
            _ = try fileManager.replaceItemAt(output, withItemAt: stagedOutput)
        } else {
            try fileManager.moveItem(at: stagedOutput, to: output)
        }
    }
}
