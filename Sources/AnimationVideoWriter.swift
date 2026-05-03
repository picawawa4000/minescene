import Foundation

enum AnimationVideoWriterError: Error, CustomStringConvertible {
    case failedToCreateWriter
    case failedToCreateWriterInput
    case failedToCreatePixelBufferAdaptor
    case failedToCreatePixelBuffer
    case failedToAppendFrame
    case failedToFinishWriting
    case ffmpegNotAvailable
    case ffmpegPipeUnavailable
    case ffmpegLaunchFailed(String)
    case ffmpegFailed(String)

    var description: String {
        switch self {
        case .failedToCreateWriter:
            return "failed to create video writer"
        case .failedToCreateWriterInput:
            return "failed to create video writer input"
        case .failedToCreatePixelBufferAdaptor:
            return "failed to create pixel buffer adaptor"
        case .failedToCreatePixelBuffer:
            return "failed to create pixel buffer"
        case .failedToAppendFrame:
            return "failed to append video frame"
        case .failedToFinishWriting:
            return "failed to finish writing video"
        case .ffmpegNotAvailable:
            return "ffmpeg was not found in PATH"
        case .ffmpegPipeUnavailable:
            return "ffmpeg stdin pipe was unavailable"
        case .ffmpegLaunchFailed(let reason):
            return "failed to launch ffmpeg: \(reason)"
        case .ffmpegFailed(let reason):
            return "ffmpeg failed: \(reason)"
        }
    }
}

#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import CoreVideo

final class AnimationVideoWriter {
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let framesPerSecond: Int

    init(outputURL: URL, width: Int, height: Int, framesPerSecond: Int) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: width * height * 8,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw AnimationVideoWriterError.failedToCreateWriterInput
        }
        writer.add(writerInput)

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        self.writerInput = writerInput
        self.framesPerSecond = framesPerSecond

        guard writer.startWriting() else {
            throw writer.error ?? AnimationVideoWriterError.failedToCreateWriter
        }
        writer.startSession(atSourceTime: .zero)
    }

    func appendFrame(_ frame: VulkanEngine.CapturedFrame, frameIndex: Int) throws {
        while !writerInput.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.001)
        }

        guard let pixelBufferPool = pixelBufferAdaptor.pixelBufferPool else {
            throw AnimationVideoWriterError.failedToCreatePixelBufferAdaptor
        }

        var pixelBufferOptional: CVPixelBuffer?
        let creationStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBufferOptional)
        guard creationStatus == kCVReturnSuccess, let pixelBuffer = pixelBufferOptional else {
            throw AnimationVideoWriterError.failedToCreatePixelBuffer
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw AnimationVideoWriterError.failedToCreatePixelBuffer
        }

        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        frame.bgra8Data.withUnsafeBytes { sourceBytes in
            guard let sourceBaseAddress = sourceBytes.baseAddress else {
                return
            }
            for rowIndex in 0..<frame.height {
                let sourceRow = sourceBaseAddress.advanced(by: rowIndex * frame.bytesPerRow)
                let destinationRow = baseAddress.advanced(by: rowIndex * destinationBytesPerRow)
                destinationRow.copyMemory(from: sourceRow, byteCount: frame.bytesPerRow)
            }
        }

        let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(framesPerSecond))
        guard pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw writer.error ?? AnimationVideoWriterError.failedToAppendFrame
        }
    }

    func finish() throws {
        writerInput.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()
        guard writer.status == .completed else {
            throw writer.error ?? AnimationVideoWriterError.failedToFinishWriting
        }
    }
}

#else

final class AnimationVideoWriter {
    private let process = Process()
    private let inputPipe = Pipe()
    private let errorPipe = Pipe()
    private let framesPerSecond: Int
    private let width: Int
    private let height: Int

    init(outputURL: URL, width: Int, height: Int, framesPerSecond: Int) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        self.framesPerSecond = framesPerSecond
        self.width = width
        self.height = height

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg",
            "-y",
            "-f", "rawvideo",
            "-pix_fmt", "bgra",
            "-s", "\(width)x\(height)",
            "-r", String(framesPerSecond),
            "-i", "-",
            "-an",
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            outputURL.path
        ]
        process.standardInput = inputPipe
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
                throw AnimationVideoWriterError.ffmpegNotAvailable
            }
            throw AnimationVideoWriterError.ffmpegLaunchFailed(String(describing: error))
        }
    }

    func appendFrame(_ frame: VulkanEngine.CapturedFrame, frameIndex: Int) throws {
        _ = frameIndex
        guard frame.width == width, frame.height == height else {
            throw AnimationVideoWriterError.failedToAppendFrame
        }
        let handle = inputPipe.fileHandleForWriting
        do {
            try handle.write(contentsOf: frame.bgra8Data)
        } catch {
            throw AnimationVideoWriterError.failedToAppendFrame
        }
    }

    func finish() throws {
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AnimationVideoWriterError.ffmpegFailed(errorText.isEmpty ? "unknown error" : errorText)
        }
    }
}

#endif
