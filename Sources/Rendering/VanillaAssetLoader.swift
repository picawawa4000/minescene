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

    enum Error: Swift.Error {
        case assetsRootNotFound(String)
        case resourceNotFound(AssetKind, AssetIdentifier)
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
                return repository
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
}

struct VanillaTextureImage {
    let width: Int
    let height: Int
    let rgba8: [UInt8]
}

final class VanillaAssetLoader {
    enum Error: Swift.Error {
        case invalidImage(URL)
        case unsupportedBitmapContext
        case textureSizeMismatch(expected: SIMD2<Int>, actual: SIMD2<Int>, texture: String)
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

    func buildAtlas(textureNames: [String]) throws -> (image: VanillaTextureImage, frames: [String: SIMD4<Float>]) {
        let uniqueTextureNames = Array(Set(textureNames)).sorted()
        let loadedTextures = try uniqueTextureNames.map { name in
            (name, try loadTexture(named: name))
        }
        guard let firstTexture = loadedTextures.first?.1 else {
            return (VanillaTextureImage(width: 1, height: 1, rgba8: [255, 255, 255, 255]), [:])
        }

        let tileSize = SIMD2<Int>(firstTexture.width, firstTexture.height)
        for (name, image) in loadedTextures {
            let size = SIMD2<Int>(image.width, image.height)
            guard size == tileSize else {
                throw Error.textureSizeMismatch(expected: tileSize, actual: size, texture: name)
            }
        }

        let columns = max(1, Int(ceil(sqrt(Double(loadedTextures.count)))))
        let rows = max(1, Int(ceil(Double(loadedTextures.count) / Double(columns))))
        let atlasWidth = columns * tileSize.x
        let atlasHeight = rows * tileSize.y
        var atlasPixels = [UInt8](repeating: 0, count: atlasWidth * atlasHeight * 4)
        var frames: [String: SIMD4<Float>] = [:]

        for (index, entry) in loadedTextures.enumerated() {
            let column = index % columns
            let row = index / columns
            let origin = SIMD2<Int>(column * tileSize.x, row * tileSize.y)
            blit(
                source: entry.1.rgba8,
                sourceSize: tileSize,
                destination: &atlasPixels,
                destinationSize: SIMD2<Int>(atlasWidth, atlasHeight),
                destinationOrigin: origin
            )

            let minU = Float(origin.x) / Float(atlasWidth)
            let minV = Float(origin.y) / Float(atlasHeight)
            let maxU = Float(origin.x + tileSize.x) / Float(atlasWidth)
            let maxV = Float(origin.y + tileSize.y) / Float(atlasHeight)
            frames[entry.0] = SIMD4<Float>(minU, minV, maxU, maxV)
        }

        return (
            VanillaTextureImage(width: atlasWidth, height: atlasHeight, rgba8: atlasPixels),
            frames
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
        return VanillaTextureImage(width: width, height: height, rgba8: pixels)
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
