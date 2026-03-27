import CoreGraphics
import Foundation
import ImageIO

struct VanillaAssetRepository {
    enum AssetKind {
        case texture
        case model
        case blockstate
    }

    struct AssetIdentifier: Hashable {
        let namespace: String
        let path: String

        init(namespace: String, path: String) {
            self.namespace = namespace
            self.path = path
        }

        init(textureIdentifier: String) {
            let parts = textureIdentifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                self.namespace = String(parts[0])
                self.path = String(parts[1])
            } else {
                self.namespace = "minecraft"
                self.path = textureIdentifier
            }
        }

        var normalizedTexturePath: String {
            var normalized = path
            if normalized.hasSuffix(".png") {
                normalized.removeLast(4)
            }
            if !normalized.hasPrefix("block/"), !normalized.hasPrefix("item/") {
                normalized = "block/" + normalized
            }
            return normalized
        }
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case assetsRootNotFound(String)
        case invalidAssetsRoot(URL)
        case resourceNotFound(AssetKind, AssetIdentifier)

        var description: String {
            switch self {
            case .assetsRootNotFound(let locationHint):
                return "vanilla assets were not found under '\(locationHint)'. Extract them with `Scripts/download_vanilla_assets.py <version>` or set MINESCENE_VANILLA_ASSETS_PATH to a directory containing `assets/`."
            case .invalidAssetsRoot(let url):
                return "invalid vanilla asset root '\(url.path)'. Expected a directory containing `assets/`."
            case .resourceNotFound(let kind, let identifier):
                return "missing \(kind.description) resource \(identifier.namespace):\(identifier.path)"
            }
        }
    }

    let rootURL: URL

    var assetsURL: URL {
        rootURL.appendingPathComponent("assets", isDirectory: true)
    }

    func textureURL(for identifier: AssetIdentifier) throws -> URL {
        try resourceURL(kind: .texture, for: identifier)
    }

    func modelURL(for identifier: AssetIdentifier) throws -> URL {
        try resourceURL(kind: .model, for: identifier)
    }

    func blockstateURL(for identifier: AssetIdentifier) throws -> URL {
        try resourceURL(kind: .blockstate, for: identifier)
    }

    func blockstateIdentifiers() throws -> [AssetIdentifier] {
        let fileManager = FileManager.default
        guard let namespaceEnumerator = fileManager.enumerator(
            at: assetsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var identifiers: [AssetIdentifier] = []
        for case let fileURL as URL in namespaceEnumerator {
            let standardizedPath = fileURL.standardizedFileURL.path
            guard standardizedPath.hasSuffix(".json"),
                  standardizedPath.contains("/assets/"),
                  standardizedPath.contains("/blockstates/") else {
                continue
            }

            let pathComponents = fileURL.pathComponents
            guard let assetsIndex = pathComponents.lastIndex(of: "assets"),
                  assetsIndex + 2 < pathComponents.count else {
                continue
            }
            let namespace = pathComponents[assetsIndex + 1]
            let kind = pathComponents[assetsIndex + 2]
            guard kind == "blockstates" else {
                continue
            }
            let relativeComponents = Array(pathComponents[(assetsIndex + 3)...])
            let relativePath = relativeComponents.joined(separator: "/").replacingOccurrences(of: ".json", with: "")
            identifiers.append(AssetIdentifier(namespace: namespace, path: relativePath))
        }

        return identifiers.sorted {
            if $0.namespace != $1.namespace {
                return $0.namespace < $1.namespace
            }
            return $0.path < $1.path
        }
    }

    static func locate(version: String? = nil, relativeRoot: String = "vanilla") throws -> VanillaAssetRepository {
        let fileManager = FileManager.default
        let candidateBaseURLs = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
            URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent(),
            URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent("../Resources", isDirectory: true)
                .standardizedFileURL
        ]

        for baseURL in candidateBaseURLs {
            let rootURL = baseURL.appendingPathComponent(relativeRoot, isDirectory: true)
            if let repository = findRepository(in: rootURL, version: version) {
                return try repository.validated()
            }
        }

        throw Error.assetsRootNotFound(version ?? relativeRoot)
    }

    private static func findRepository(in rootURL: URL, version: String?) -> VanillaAssetRepository? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return nil
        }

        if let version {
            let versionURL = rootURL.appendingPathComponent(version, isDirectory: true)
            let assetsURL = versionURL.appendingPathComponent("assets", isDirectory: true)
            guard fileManager.fileExists(atPath: assetsURL.path) else {
                return nil
            }
            return VanillaAssetRepository(rootURL: versionURL)
        }

        let versionDirectories = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let sortedCandidates = versionDirectories.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for candidateURL in sortedCandidates {
            let assetsURL = candidateURL.appendingPathComponent("assets", isDirectory: true)
            if fileManager.fileExists(atPath: assetsURL.path) {
                return VanillaAssetRepository(rootURL: candidateURL)
            }
        }
        return nil
    }

    private func resourceURL(kind: AssetKind, for identifier: AssetIdentifier) throws -> URL {
        let relativePath: String
        switch kind {
        case .texture:
            relativePath = "textures/\(identifier.normalizedTexturePath).png"
        case .model:
            relativePath = "models/\(identifier.path).json"
        case .blockstate:
            relativePath = "blockstates/\(identifier.path).json"
        }

        let url = assetsURL
            .appendingPathComponent(identifier.namespace, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.resourceNotFound(kind, identifier)
        }
        return url
    }

    func validated() throws -> VanillaAssetRepository {
        let assetsURL = self.assetsURL
        guard FileManager.default.fileExists(atPath: assetsURL.path) else {
            throw Error.invalidAssetsRoot(rootURL)
        }
        return self
    }
}

private extension VanillaAssetRepository.AssetKind {
    var description: String {
        switch self {
        case .texture:
            return "texture"
        case .model:
            return "model"
        case .blockstate:
            return "blockstate"
        }
    }
}

struct VanillaTextureImage {
    struct AnimationFrame {
        let index: Int
        let time: Int
    }

    let width: Int
    let height: Int
    let rgba8: [UInt8]
    let frameWidth: Int
    let frameHeight: Int
    let frameCount: Int
    let animationFrames: [AnimationFrame]
    let animationOrientation: AnimationOrientation

    enum AnimationOrientation {
        case none
        case vertical
        case horizontal
    }

    var logicalSize: SIMD2<Int> {
        SIMD2<Int>(frameWidth, frameHeight)
    }

    func animationFrameIndex(for tick: Int) -> Int {
        guard !animationFrames.isEmpty else {
            return 0
        }
        let safeTick = max(0, tick)
        let totalDuration = animationFrames.reduce(0) { $0 + max(1, $1.time) }
        guard totalDuration > 0 else {
            return animationFrames[0].index
        }
        var remaining = safeTick % totalDuration
        for frame in animationFrames {
            let duration = max(1, frame.time)
            if remaining < duration {
                return min(max(0, frame.index), max(0, frameCount - 1))
            }
            remaining -= duration
        }
        return min(max(0, animationFrames[0].index), max(0, frameCount - 1))
    }

    func pixels(forAnimationTick tick: Int) -> [UInt8] {
        let selectedFrameIndex = animationFrameIndex(for: tick)
        let destinationByteCount = frameWidth * frameHeight * 4
        guard frameCount > 1 else {
            if rgba8.count == destinationByteCount {
                return rgba8
            }
            return Array(rgba8.prefix(destinationByteCount))
        }

        var framePixels = [UInt8](repeating: 0, count: destinationByteCount)
        let sourceRowBytes = width * 4
        let destinationRowBytes = frameWidth * 4

        switch animationOrientation {
        case .none:
            return Array(rgba8.prefix(destinationByteCount))
        case .vertical:
            let sourceOriginY = selectedFrameIndex * frameHeight
            for row in 0..<frameHeight {
                let sourceOffset = ((sourceOriginY + row) * sourceRowBytes)
                let destinationOffset = row * destinationRowBytes
                framePixels.withUnsafeMutableBufferPointer { destinationBuffer in
                    rgba8.withUnsafeBufferPointer { sourceBuffer in
                        let destinationBase = destinationBuffer.baseAddress!.advanced(by: destinationOffset)
                        let sourceBase = sourceBuffer.baseAddress!.advanced(by: sourceOffset)
                        destinationBase.update(from: sourceBase, count: destinationRowBytes)
                    }
                }
            }
            return framePixels
        case .horizontal:
            let sourceOriginX = selectedFrameIndex * frameWidth
            for row in 0..<frameHeight {
                let sourceOffset = (row * sourceRowBytes) + (sourceOriginX * 4)
                let destinationOffset = row * destinationRowBytes
                framePixels.withUnsafeMutableBufferPointer { destinationBuffer in
                    rgba8.withUnsafeBufferPointer { sourceBuffer in
                        let destinationBase = destinationBuffer.baseAddress!.advanced(by: destinationOffset)
                        let sourceBase = sourceBuffer.baseAddress!.advanced(by: sourceOffset)
                        destinationBase.update(from: sourceBase, count: destinationRowBytes)
                    }
                }
            }
            return framePixels
        }
    }
}

final class VanillaAssetLoader {
    struct AtlasBuild {
        let image: VanillaTextureImage
        let frames: [String: SIMD4<Float>]
        let animationSignature: [String: Int]
    }

    enum Error: Swift.Error {
        case invalidImage(URL)
        case unsupportedBitmapContext
        case unsupportedTextureDimensions(texture: String, size: SIMD2<Int>)
    }

    let repository: VanillaAssetRepository
    private var textureCache: [VanillaAssetRepository.AssetIdentifier: VanillaTextureImage] = [:]

    init(repository: VanillaAssetRepository) {
        self.repository = repository
    }

    func loadTexture(named textureIdentifier: String) throws -> VanillaTextureImage {
        let identifier = VanillaAssetRepository.AssetIdentifier(textureIdentifier: textureIdentifier)
        if let cached = textureCache[identifier] {
            return cached
        }

        let textureURL = try repository.textureURL(for: identifier)
        let image = try Self.decodeImage(at: textureURL)
        textureCache[identifier] = image
        return image
    }

    func buildAtlas(textureNames: [String], animationTick: Int = 0) throws -> AtlasBuild {
        let uniqueTextureNames = Array(Set(textureNames)).sorted()
        let loadedTextures = try uniqueTextureNames.map { name in
            (name, try loadTexture(named: name))
        }
        guard let firstTexture = loadedTextures.first?.1 else {
            return AtlasBuild(
                image: VanillaTextureImage(
                    width: 1,
                    height: 1,
                    rgba8: [255, 255, 255, 255],
                    frameWidth: 1,
                    frameHeight: 1,
                    frameCount: 1,
                    animationFrames: [],
                    animationOrientation: .none
                ),
                frames: [:],
                animationSignature: [:]
            )
        }

        let tileSizes = loadedTextures.map { (name: $0.0, size: $0.1.logicalSize) }
        for entry in tileSizes {
            guard entry.size.x == entry.size.y,
                  entry.size.x > 0,
                  isPowerOfTwo(entry.size.x) else {
                throw Error.unsupportedTextureDimensions(texture: entry.name, size: entry.size)
            }
        }
        let maxTileSide = tileSizes.map(\.size.x).max() ?? firstTexture.logicalSize.x
        let atlasCellSize = SIMD2<Int>(maxTileSide, maxTileSide)

        let columns = max(1, Int(ceil(sqrt(Double(loadedTextures.count)))))
        let rows = max(1, Int(ceil(Double(loadedTextures.count) / Double(columns))))
        let atlasWidth = columns * atlasCellSize.x
        let atlasHeight = rows * atlasCellSize.y
        var atlasPixels = [UInt8](repeating: 0, count: atlasWidth * atlasHeight * 4)
        var frames: [String: SIMD4<Float>] = [:]
        var animationSignature: [String: Int] = [:]

        for (index, entry) in loadedTextures.enumerated() {
            let column = index % columns
            let row = index / columns
            let textureSize = entry.1.logicalSize
            let origin = SIMD2<Int>(column * atlasCellSize.x, row * atlasCellSize.y)
            let frameIndex = entry.1.animationFrameIndex(for: animationTick)
            blit(
                source: entry.1.pixels(forAnimationTick: animationTick),
                sourceSize: textureSize,
                destination: &atlasPixels,
                destinationSize: SIMD2<Int>(atlasWidth, atlasHeight),
                destinationOrigin: origin
            )
            animationSignature[entry.0] = frameIndex

            let minU = Float(origin.x) / Float(atlasWidth)
            let minV = Float(origin.y) / Float(atlasHeight)
            let maxU = Float(origin.x + textureSize.x) / Float(atlasWidth)
            let maxV = Float(origin.y + textureSize.y) / Float(atlasHeight)
            frames[entry.0] = SIMD4<Float>(minU, minV, maxU, maxV)
        }

        return AtlasBuild(
            image: VanillaTextureImage(
                width: atlasWidth,
                height: atlasHeight,
                rgba8: atlasPixels,
                frameWidth: atlasWidth,
                frameHeight: atlasHeight,
                frameCount: 1,
                animationFrames: [],
                animationOrientation: .none
            ),
            frames: frames,
            animationSignature: animationSignature
        )
    }

    private static func decodeImage(at url: URL) throws -> VanillaTextureImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Error.invalidImage(url)
        }

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(.init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bytesPerRow = width * 4

        let createdContext = pixels.withUnsafeMutableBytes { rawBytes in
            CGContext(
                data: rawBytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        }
        guard let context = createdContext else {
            throw Error.unsupportedBitmapContext
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let animationMetadata = loadAnimationMetadata(at: url)
        let animationInfo = computeAnimationLayout(
            width: width,
            height: height,
            metadata: animationMetadata
        )
        return VanillaTextureImage(
            width: width,
            height: height,
            rgba8: pixels,
            frameWidth: animationInfo.frameWidth,
            frameHeight: animationInfo.frameHeight,
            frameCount: animationInfo.frameCount,
            animationFrames: animationInfo.frames,
            animationOrientation: animationInfo.orientation
        )
    }

    private struct AnimationMetadata {
        struct Frame {
            let index: Int
            let time: Int?
        }

        let frametime: Int
        let frames: [Frame]?
    }

    private struct AnimationInfo {
        let frameWidth: Int
        let frameHeight: Int
        let frameCount: Int
        let frames: [VanillaTextureImage.AnimationFrame]
        let orientation: VanillaTextureImage.AnimationOrientation
    }

    private static func loadAnimationMetadata(at textureURL: URL) -> AnimationMetadata? {
        let metadataURL = textureURL.appendingPathExtension("mcmeta")
        guard FileManager.default.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let animation = object["animation"] as? [String: Any] else {
            return nil
        }

        let frametime = max(1, animation["frametime"] as? Int ?? 1)
        let frames: [AnimationMetadata.Frame]?
        if let rawFrames = animation["frames"] as? [Any] {
            frames = rawFrames.compactMap { item in
                if let index = item as? Int {
                    return AnimationMetadata.Frame(index: index, time: nil)
                }
                if let object = item as? [String: Any], let index = object["index"] as? Int {
                    return AnimationMetadata.Frame(index: index, time: object["time"] as? Int)
                }
                return nil
            }
        } else {
            frames = nil
        }
        return AnimationMetadata(frametime: frametime, frames: frames)
    }

    private static func computeAnimationLayout(
        width: Int,
        height: Int,
        metadata: AnimationMetadata?
    ) -> AnimationInfo {
        let orientation: VanillaTextureImage.AnimationOrientation
        let frameWidth: Int
        let frameHeight: Int
        let frameCount: Int

        if height > width, height % width == 0 {
            orientation = .vertical
            frameWidth = width
            frameHeight = width
            frameCount = height / width
        } else if width > height, width % height == 0 {
            orientation = .horizontal
            frameWidth = height
            frameHeight = height
            frameCount = width / height
        } else {
            orientation = .none
            frameWidth = width
            frameHeight = height
            frameCount = 1
        }

        let defaultFrameTime = metadata?.frametime ?? 1
        let frames: [VanillaTextureImage.AnimationFrame]
        if frameCount <= 1 {
            frames = []
        } else if let metadataFrames = metadata?.frames, !metadataFrames.isEmpty {
            frames = metadataFrames.map { frame in
                VanillaTextureImage.AnimationFrame(
                    index: min(max(0, frame.index), max(0, frameCount - 1)),
                    time: max(1, frame.time ?? defaultFrameTime)
                )
            }
        } else {
            frames = (0..<frameCount).map {
                VanillaTextureImage.AnimationFrame(index: $0, time: defaultFrameTime)
            }
        }

        return AnimationInfo(
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            frameCount: frameCount,
            frames: frames,
            orientation: orientation
        )
    }

    private func isPowerOfTwo(_ value: Int) -> Bool {
        value > 0 && (value & (value - 1)) == 0
    }

    private func blit(
        source: [UInt8],
        sourceSize: SIMD2<Int>,
        destination: inout [UInt8],
        destinationSize: SIMD2<Int>,
        destinationOrigin: SIMD2<Int>
    ) {
        let sourceRowBytes = sourceSize.x * 4
        let destinationRowBytes = destinationSize.x * 4
        for row in 0..<sourceSize.y {
            let sourceOffset = row * sourceRowBytes
            let destinationOffset = ((destinationOrigin.y + row) * destinationRowBytes) + (destinationOrigin.x * 4)
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                source.withUnsafeBufferPointer { sourceBuffer in
                    let destinationBase = destinationBuffer.baseAddress!.advanced(by: destinationOffset)
                    let sourceBase = sourceBuffer.baseAddress!.advanced(by: sourceOffset)
                    destinationBase.update(from: sourceBase, count: sourceRowBytes)
                }
            }
        }
    }
}
