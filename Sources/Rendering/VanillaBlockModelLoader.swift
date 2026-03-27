import Foundation
#if canImport(simd)
import simd
#endif

enum VanillaBlockFaceDirection: String, CaseIterable {
    case down
    case up
    case north
    case south
    case west
    case east
}

enum VanillaBlockModelAxis: String {
    case x
    case y
    case z
}

struct VanillaResolvedBlockModel {
    struct Rotation {
        let origin: SIMD3<Float>
        let axis: VanillaBlockModelAxis
        let angle: Float
        let rescale: Bool
    }

    struct Face {
        let direction: VanillaBlockFaceDirection
        let textureName: String
        let uv: SIMD4<Float>
        let rotation: Int
        let tintIndex: Int?
    }

    struct Element {
        let from: SIMD3<Float>
        let to: SIMD3<Float>
        let rotation: Rotation?
        let shade: Bool
        let faces: [VanillaBlockFaceDirection: Face]
    }

    let identifier: VanillaAssetRepository.AssetIdentifier
    let ambientOcclusion: Bool
    let elements: [Element]
}

struct VanillaResolvedBlockState {
    struct Placement {
        let model: VanillaResolvedBlockModel
        let xRotationDegrees: Int
        let yRotationDegrees: Int
        let uvLock: Bool
    }

    let identifier: VanillaAssetRepository.AssetIdentifier
    let selectedKey: String?
    let placements: [Placement]
}

final class VanillaBlockModelLoader {
    enum Error: Swift.Error {
        case invalidJSON(URL)
        case malformedModel(URL, String)
        case malformedBlockstate(URL, String)
        case unsupportedParent(String)
        case missingTextureVariable(String, model: String)
    }

    private struct RawModelFile: Decodable {
        struct ElementRotation: Decodable {
            let origin: [Float]
            let axis: String
            let angle: Float
            let rescale: Bool?
        }

        struct ElementFace: Decodable {
            let uv: [Float]?
            let texture: String
            let cullface: String?
            let rotation: Int?
            let tintindex: Int?
        }

        struct Element: Decodable {
            let from: [Float]
            let to: [Float]
            let rotation: ElementRotation?
            let shade: Bool?
            let faces: [String: ElementFace]
        }

        let parent: String?
        let ambientocclusion: Bool?
        let textures: [String: String]?
        let elements: [Element]?
    }

    private struct ModelResolutionContext {
        let ambientOcclusion: Bool
        let textures: [String: String]
        let rawElements: [RawModelFile.Element]
    }

    private let repository: VanillaAssetRepository
    private var rawModelCache: [VanillaAssetRepository.AssetIdentifier: RawModelFile] = [:]
    private var resolvedModelCache: [VanillaAssetRepository.AssetIdentifier: VanillaResolvedBlockModel] = [:]
    private var loggedFallbackModels: Set<VanillaAssetRepository.AssetIdentifier> = []

    init(repository: VanillaAssetRepository) {
        self.repository = repository
    }

    func loadResolvedModel(named modelIdentifier: String) throws -> VanillaResolvedBlockModel {
        try loadResolvedModel(identifier: parseIdentifier(modelIdentifier))
    }

    func loadRepresentativeBlockstates(limit: Int? = nil) throws -> [VanillaResolvedBlockState] {
        let identifiers = try repository.blockstateIdentifiers()
        let cappedIdentifiers: ArraySlice<VanillaAssetRepository.AssetIdentifier>
        if let limit {
            cappedIdentifiers = identifiers.prefix(max(0, limit))
        } else {
            cappedIdentifiers = identifiers[...]
        }

        var resolvedStates: [VanillaResolvedBlockState] = []
        resolvedStates.reserveCapacity(cappedIdentifiers.count)
        for identifier in cappedIdentifiers {
            do {
                if let state = try loadRepresentativeBlockstate(identifier: identifier) {
                    resolvedStates.append(state)
                }
            } catch {
                let message = "Skipping blockstate \(identifier.namespace):\(identifier.path): \(error)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
        }
        return resolvedStates
    }

    func texturedQuads(
        for state: VanillaResolvedBlockState,
        worldOffset: SIMD3<Float> = .zero
    ) -> [StructureRenderer.TexturedQuad] {
        var quads: [StructureRenderer.TexturedQuad] = []
        for placement in state.placements {
            if placement.model.elements.isEmpty {
                logPlaceholderFallbackIfNeeded(for: placement.model.identifier)
                quads.append(contentsOf: placeholderQuads(for: placement, worldOffset: worldOffset))
                continue
            }
            for element in placement.model.elements {
                for direction in VanillaBlockFaceDirection.allCases {
                    guard let face = element.faces[direction] else {
                        continue
                    }
                    let baseCorners = corners(for: direction, from: element.from, to: element.to)
                    let rotatedElementCorners = baseCorners.map { corner in
                        guard let rotation = element.rotation else {
                            return corner
                        }
                        return rotate(point: corner, around: rotation.origin / 16, axis: rotation.axis, degrees: rotation.angle)
                    }
                    let finalCorners = rotatedElementCorners.map { corner in
                        let xRotated = rotateVariant(point: corner, axis: .x, degrees: placement.xRotationDegrees)
                        let xyRotated = rotateVariant(point: xRotated, axis: .y, degrees: placement.yRotationDegrees)
                        return xyRotated + worldOffset
                    }
                    quads.append(
                        StructureRenderer.TexturedQuad(
                            corners: finalCorners,
                            textureName: face.textureName,
                            tint: shadedTint(for: direction, shade: element.shade),
                            textureCoordinates: textureCoordinates(
                                for: face,
                                from: element.from,
                                to: element.to,
                                corners: baseCorners
                            )
                        )
                    )
                }
            }
        }
        return quads
    }

    private func loadRepresentativeBlockstate(
        identifier: VanillaAssetRepository.AssetIdentifier
    ) throws -> VanillaResolvedBlockState? {
        let url = try repository.blockstateURL(for: identifier)
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw Error.invalidJSON(url)
        }

        if let variantsObject = root["variants"] as? [String: Any] {
            let keys = variantsObject.keys.sorted()
            guard let selectedKey = (keys.contains("") ? "" : keys.first),
                  let variantValue = variantsObject[selectedKey] else {
                return nil
            }
            let placements = try decodePlacements(fromVariantValue: variantValue)
            let resolvedPlacements = try placements.map(resolvePlacement)
            return VanillaResolvedBlockState(identifier: identifier, selectedKey: selectedKey, placements: resolvedPlacements)
        }

        if let multipartArray = root["multipart"] as? [Any] {
            let multipartEntries = multipartArray.compactMap { $0 as? [String: Any] }
            let representativeValues = chooseRepresentativeMultipartValues(from: multipartEntries)
            let applyValues = multipartEntries.compactMap { entry -> Any? in
                guard let apply = entry["apply"] else {
                    return nil
                }
                guard let when = entry["when"] else {
                    return apply
                }
                return multipartConditionMatches(when, values: representativeValues) ? apply : nil
            }
            let placements = try applyValues.flatMap { try decodePlacements(fromVariantValue: $0) }
            guard !placements.isEmpty else {
                return nil
            }
            let resolvedPlacements = try placements.map(resolvePlacement)
            return VanillaResolvedBlockState(identifier: identifier, selectedKey: nil, placements: resolvedPlacements)
        }

        throw Error.malformedBlockstate(url, "expected variants or multipart")
    }

    private func resolvePlacement(_ rawPlacement: [String: Any]) throws -> VanillaResolvedBlockState.Placement {
        guard let modelName = rawPlacement["model"] as? String else {
            throw Error.malformedBlockstate(repository.rootURL, "missing model reference")
        }
        let model = try loadResolvedModel(named: modelName)
        let xRotation = (rawPlacement["x"] as? Int) ?? 0
        let yRotation = (rawPlacement["y"] as? Int) ?? 0
        let uvLock = (rawPlacement["uvlock"] as? Bool) ?? false
        return VanillaResolvedBlockState.Placement(
            model: model,
            xRotationDegrees: xRotation,
            yRotationDegrees: yRotation,
            uvLock: uvLock
        )
    }

    private func decodePlacements(fromVariantValue value: Any) throws -> [[String: Any]] {
        if let object = value as? [String: Any] {
            return [object]
        }
        if let array = value as? [[String: Any]] {
            if let first = array.first {
                return [first]
            }
            return []
        }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? [String: Any] }.prefix(1).map { $0 }
        }
        throw Error.malformedBlockstate(repository.rootURL, "invalid placement value")
    }

    private func loadResolvedModel(
        identifier: VanillaAssetRepository.AssetIdentifier
    ) throws -> VanillaResolvedBlockModel {
        if let cached = resolvedModelCache[identifier] {
            return cached
        }

        let resolved = try resolveModel(identifier: identifier, visited: [])
        resolvedModelCache[identifier] = resolved
        return resolved
    }

    private func resolveModel(
        identifier: VanillaAssetRepository.AssetIdentifier,
        visited: Set<VanillaAssetRepository.AssetIdentifier>
    ) throws -> VanillaResolvedBlockModel {
        let context = try resolveModelContext(identifier: identifier, visited: visited)
        let elements = try context.rawElements.map {
            try resolveElement($0, textures: context.textures, modelIdentifier: identifier)
        }

        return VanillaResolvedBlockModel(
            identifier: identifier,
            ambientOcclusion: context.ambientOcclusion,
            elements: elements
        )
    }

    private func resolveModelContext(
        identifier: VanillaAssetRepository.AssetIdentifier,
        visited: Set<VanillaAssetRepository.AssetIdentifier>
    ) throws -> ModelResolutionContext {
        if visited.contains(identifier) {
            throw Error.malformedModel(try repository.modelURL(for: identifier), "cyclic parent chain")
        }

        let raw = try loadRawModel(identifier: identifier)
        if let parentName = raw.parent {
            if parentName.hasPrefix("builtin/") {
                throw Error.unsupportedParent(parentName)
            }

            let parentIdentifier = parseIdentifier(parentName)
            let parentContext = try resolveModelContext(
                identifier: parentIdentifier,
                visited: visited.union([identifier])
            )
            return ModelResolutionContext(
                ambientOcclusion: raw.ambientocclusion ?? parentContext.ambientOcclusion,
                textures: parentContext.textures.merging(raw.textures ?? [:]) { _, child in child },
                rawElements: raw.elements ?? parentContext.rawElements
            )
        }

        return ModelResolutionContext(
            ambientOcclusion: raw.ambientocclusion ?? true,
            textures: raw.textures ?? [:],
            rawElements: raw.elements ?? []
        )
    }

    private func resolveElement(
        _ rawElement: RawModelFile.Element,
        textures: [String: String],
        modelIdentifier: VanillaAssetRepository.AssetIdentifier
    ) throws -> VanillaResolvedBlockModel.Element {
        guard rawElement.from.count == 3, rawElement.to.count == 3 else {
            throw Error.malformedModel(try repository.modelURL(for: modelIdentifier), "elements require 3-component from/to")
        }

        let from = SIMD3<Float>(rawElement.from[0] / 16, rawElement.from[1] / 16, rawElement.from[2] / 16)
        let to = SIMD3<Float>(rawElement.to[0] / 16, rawElement.to[1] / 16, rawElement.to[2] / 16)
        let rotation: VanillaResolvedBlockModel.Rotation?
        if let rawRotation = rawElement.rotation {
            guard rawRotation.origin.count == 3,
                  let axis = VanillaBlockModelAxis(rawValue: rawRotation.axis) else {
                throw Error.malformedModel(try repository.modelURL(for: modelIdentifier), "invalid element rotation")
            }
            rotation = VanillaResolvedBlockModel.Rotation(
                origin: SIMD3<Float>(rawRotation.origin[0], rawRotation.origin[1], rawRotation.origin[2]),
                axis: axis,
                angle: rawRotation.angle,
                rescale: rawRotation.rescale ?? false
            )
        } else {
            rotation = nil
        }

        var faces: [VanillaBlockFaceDirection: VanillaResolvedBlockModel.Face] = [:]
        for direction in VanillaBlockFaceDirection.allCases {
            guard let rawFace = rawElement.faces[direction.rawValue] else {
                continue
            }
            let textureName = try resolveTextureName(
                rawFace.texture,
                textures: textures,
                modelIdentifier: modelIdentifier
            )
            let uvRect: SIMD4<Float>
            if let uv = rawFace.uv, uv.count == 4 {
                uvRect = SIMD4<Float>(uv[0], uv[1], uv[2], uv[3])
            } else {
                uvRect = defaultUV(for: direction, from: rawElement.from, to: rawElement.to)
            }
            faces[direction] = VanillaResolvedBlockModel.Face(
                direction: direction,
                textureName: textureName,
                uv: uvRect,
                rotation: rawFace.rotation ?? 0,
                tintIndex: rawFace.tintindex
            )
        }

        return VanillaResolvedBlockModel.Element(
            from: from,
            to: to,
            rotation: rotation,
            shade: rawElement.shade ?? true,
            faces: faces
        )
    }

    private func resolveTextureName(
        _ reference: String,
        textures: [String: String],
        modelIdentifier: VanillaAssetRepository.AssetIdentifier
    ) throws -> String {
        var resolved = reference
        var remainingExpansions = 16
        while resolved.hasPrefix("#") || shouldExpandBareTextureAlias(resolved, textures: textures) {
            guard remainingExpansions > 0 else {
                break
            }
            remainingExpansions -= 1
            let key = resolved.hasPrefix("#") ? String(resolved.dropFirst()) : resolved
            guard let next = textures[key] else {
                throw Error.missingTextureVariable(key, model: "\(modelIdentifier.namespace):\(modelIdentifier.path)")
            }
            resolved = next
        }
        return resolved
    }

    private func shouldExpandBareTextureAlias(_ value: String, textures: [String: String]) -> Bool {
        guard !value.hasPrefix("#"),
              !value.contains("/"),
              !value.contains(":"),
              textures[value] != nil else {
            return false
        }
        return true
    }

    private func loadRawModel(identifier: VanillaAssetRepository.AssetIdentifier) throws -> RawModelFile {
        if let cached = rawModelCache[identifier] {
            return cached
        }

        let url = try repository.modelURL(for: identifier)
        let data = try Data(contentsOf: url)
        let rawModel = try JSONDecoder().decode(RawModelFile.self, from: data)
        rawModelCache[identifier] = rawModel
        return rawModel
    }

    private func parseIdentifier(_ reference: String) -> VanillaAssetRepository.AssetIdentifier {
        let parts = reference.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            return .init(namespace: String(parts[0]), path: String(parts[1]))
        }
        return .init(namespace: "minecraft", path: reference)
    }

    private func defaultUV(
        for direction: VanillaBlockFaceDirection,
        from: [Float],
        to: [Float]
    ) -> SIMD4<Float> {
        switch direction {
        case .down:
            return SIMD4<Float>(from[0], 16 - to[2], to[0], 16 - from[2])
        case .up:
            return SIMD4<Float>(from[0], from[2], to[0], to[2])
        case .north:
            return SIMD4<Float>(16 - to[0], 16 - to[1], 16 - from[0], 16 - from[1])
        case .south:
            return SIMD4<Float>(from[0], 16 - to[1], to[0], 16 - from[1])
        case .west:
            return SIMD4<Float>(from[2], 16 - to[1], to[2], 16 - from[1])
        case .east:
            return SIMD4<Float>(16 - to[2], 16 - to[1], 16 - from[2], 16 - from[1])
        }
    }

    private func corners(
        for direction: VanillaBlockFaceDirection,
        from: SIMD3<Float>,
        to: SIMD3<Float>
    ) -> [SIMD3<Float>] {
        switch direction {
        case .up:
            return [
                SIMD3<Float>(from.x, to.y, from.z),
                SIMD3<Float>(to.x, to.y, from.z),
                SIMD3<Float>(to.x, to.y, to.z),
                SIMD3<Float>(from.x, to.y, to.z)
            ]
        case .down:
            return [
                SIMD3<Float>(from.x, from.y, from.z),
                SIMD3<Float>(from.x, from.y, to.z),
                SIMD3<Float>(to.x, from.y, to.z),
                SIMD3<Float>(to.x, from.y, from.z)
            ]
        case .north:
            return [
                SIMD3<Float>(from.x, from.y, from.z),
                SIMD3<Float>(to.x, from.y, from.z),
                SIMD3<Float>(to.x, to.y, from.z),
                SIMD3<Float>(from.x, to.y, from.z)
            ]
        case .south:
            return [
                SIMD3<Float>(to.x, from.y, to.z),
                SIMD3<Float>(from.x, from.y, to.z),
                SIMD3<Float>(from.x, to.y, to.z),
                SIMD3<Float>(to.x, to.y, to.z)
            ]
        case .east:
            return [
                SIMD3<Float>(to.x, from.y, from.z),
                SIMD3<Float>(to.x, from.y, to.z),
                SIMD3<Float>(to.x, to.y, to.z),
                SIMD3<Float>(to.x, to.y, from.z)
            ]
        case .west:
            return [
                SIMD3<Float>(from.x, from.y, to.z),
                SIMD3<Float>(from.x, from.y, from.z),
                SIMD3<Float>(from.x, to.y, from.z),
                SIMD3<Float>(from.x, to.y, to.z)
            ]
        }
    }

    private func shadedTint(for direction: VanillaBlockFaceDirection, shade: Bool) -> SIMD4<Float> {
        guard shade else {
            return SIMD4<Float>(repeating: 1)
        }
        let brightness: Float
        switch direction {
        case .up:
            brightness = 1.0
        case .down:
            brightness = 0.58
        case .north, .south:
            brightness = 0.8
        case .east, .west:
            brightness = 0.68
        }
        return SIMD4<Float>(brightness, brightness, brightness, 1)
    }

    private func rotateVariant(
        point: SIMD3<Float>,
        axis: VanillaBlockModelAxis,
        degrees: Int
    ) -> SIMD3<Float> {
        guard degrees != 0 else {
            return point
        }
        return rotate(
            point: point,
            around: SIMD3<Float>(0.5, 0.5, 0.5),
            axis: axis,
            degrees: Float(degrees)
        )
    }

    private func rotate(
        point: SIMD3<Float>,
        around origin: SIMD3<Float>,
        axis: VanillaBlockModelAxis,
        degrees: Float
    ) -> SIMD3<Float> {
        let radians = degrees * .pi / 180
        let translated = point - origin
        let cosAngle = cos(radians)
        let sinAngle = sin(radians)

        let rotated: SIMD3<Float>
        switch axis {
        case .x:
            rotated = SIMD3<Float>(
                translated.x,
                translated.y * cosAngle - translated.z * sinAngle,
                translated.y * sinAngle + translated.z * cosAngle
            )
        case .y:
            rotated = SIMD3<Float>(
                translated.x * cosAngle + translated.z * sinAngle,
                translated.y,
                -translated.x * sinAngle + translated.z * cosAngle
            )
        case .z:
            rotated = SIMD3<Float>(
                translated.x * cosAngle - translated.y * sinAngle,
                translated.x * sinAngle + translated.y * cosAngle,
                translated.z
            )
        }
        return rotated + origin
    }

    private func textureCoordinates(
        for face: VanillaResolvedBlockModel.Face,
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        corners: [SIMD3<Float>]
    ) -> [SIMD2<Float>] {
        let minU = face.uv.x / 16
        let minV = face.uv.y / 16
        let maxU = face.uv.z / 16
        let maxV = face.uv.w / 16
        return corners.map { corner in
            let localUV = rotatedFaceUV(
                localFaceUV(for: face.direction, corner: corner, from: from, to: to),
                degrees: face.rotation
            )
            return SIMD2<Float>(
                minU + (maxU - minU) * localUV.x,
                minV + (maxV - minV) * localUV.y
            )
        }
    }

    private func localFaceUV(
        for direction: VanillaBlockFaceDirection,
        corner: SIMD3<Float>,
        from: SIMD3<Float>,
        to: SIMD3<Float>
    ) -> SIMD2<Float> {
        let size = max(to - from, SIMD3<Float>(repeating: 0.0001))

        switch direction {
        case .down:
            return SIMD2<Float>(
                (corner.x - from.x) / size.x,
                (to.z - corner.z) / size.z
            )
        case .up:
            return SIMD2<Float>(
                (corner.x - from.x) / size.x,
                (corner.z - from.z) / size.z
            )
        case .north:
            return SIMD2<Float>(
                (to.x - corner.x) / size.x,
                (to.y - corner.y) / size.y
            )
        case .south:
            return SIMD2<Float>(
                (corner.x - from.x) / size.x,
                (to.y - corner.y) / size.y
            )
        case .west:
            return SIMD2<Float>(
                (corner.z - from.z) / size.z,
                (to.y - corner.y) / size.y
            )
        case .east:
            return SIMD2<Float>(
                (to.z - corner.z) / size.z,
                (to.y - corner.y) / size.y
            )
        }
    }

    private func rotatedFaceUV(_ uv: SIMD2<Float>, degrees: Int) -> SIMD2<Float> {
        switch ((degrees % 360) + 360) % 360 {
        case 90:
            return SIMD2<Float>(1 - uv.y, uv.x)
        case 180:
            return SIMD2<Float>(1 - uv.x, 1 - uv.y)
        case 270:
            return SIMD2<Float>(uv.y, 1 - uv.x)
        default:
            return uv
        }
    }

    private func placeholderQuads(
        for placement: VanillaResolvedBlockState.Placement,
        worldOffset: SIMD3<Float>
    ) -> [StructureRenderer.TexturedQuad] {
        let from = SIMD3<Float>(repeating: 0.25)
        let to = SIMD3<Float>(repeating: 0.75)
        let tint = SIMD4<Float>(1, 0, 0, 1)
        let textureName = "minecraft:block/white_concrete"

        return VanillaBlockFaceDirection.allCases.map { direction in
            let baseCorners = corners(for: direction, from: from, to: to)
            let finalCorners = baseCorners.map { corner in
                let xRotated = rotateVariant(point: corner, axis: .x, degrees: placement.xRotationDegrees)
                let xyRotated = rotateVariant(point: xRotated, axis: .y, degrees: placement.yRotationDegrees)
                return xyRotated + worldOffset
            }
            return StructureRenderer.TexturedQuad(
                corners: finalCorners,
                textureName: textureName,
                tint: tint
            )
        }
    }

    private func logPlaceholderFallbackIfNeeded(
        for identifier: VanillaAssetRepository.AssetIdentifier
    ) {
        guard loggedFallbackModels.insert(identifier).inserted else {
            return
        }
        let message = "Using red-cube fallback for model \(identifier.namespace):\(identifier.path)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func chooseRepresentativeMultipartValues(from entries: [[String: Any]]) -> [String: String] {
        var assignments: [String: String] = [:]
        for entry in entries {
            guard let when = entry["when"] else {
                continue
            }
            if let updatedAssignments = satisfyingAssignments(for: when, existing: assignments) {
                assignments = updatedAssignments
            }
        }
        return assignments
    }

    private func multipartConditionMatches(_ when: Any, values: [String: String]) -> Bool {
        if let dictionary = when as? [String: Any] {
            if let andArray = dictionary["AND"] as? [Any] {
                return andArray.allSatisfy { multipartConditionMatches($0, values: values) }
            }
            if let orArray = dictionary["OR"] as? [Any] {
                return orArray.contains { multipartConditionMatches($0, values: values) }
            }
            return dictionary.allSatisfy { key, value in
                guard let stringValue = value as? String,
                      let assigned = values[key] else {
                    return false
                }
                return stringValue
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map(String.init)
                    .contains(assigned)
            }
        }
        return false
    }

    private func satisfyingAssignments(
        for when: Any,
        existing: [String: String]
    ) -> [String: String]? {
        if let dictionary = when as? [String: Any] {
            if let andArray = dictionary["AND"] as? [Any] {
                var assignments = existing
                for condition in andArray {
                    guard let updatedAssignments = satisfyingAssignments(for: condition, existing: assignments) else {
                        return nil
                    }
                    assignments = updatedAssignments
                }
                return assignments
            }
            if let orArray = dictionary["OR"] as? [Any] {
                for condition in orArray {
                    if let assignments = satisfyingAssignments(for: condition, existing: existing) {
                        return assignments
                    }
                }
                return nil
            }

            var assignments = existing
            for (key, value) in dictionary {
                guard let stringValue = value as? String else {
                    return nil
                }
                let options = stringValue
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map(String.init)
                if let assigned = assignments[key] {
                    guard options.contains(assigned) else {
                        return nil
                    }
                } else if let selected = options.first {
                    assignments[key] = selected
                } else {
                    return nil
                }
            }
            return assignments
        }
        return nil
    }
}
