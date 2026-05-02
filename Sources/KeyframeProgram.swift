import Foundation
#if canImport(simd)
import simd
#endif

struct KeyframeProgram {
    struct Attributes {
        var renderDistance: Int?
        var lodNearDistance: Int?
        var lodStepDistance: Int?
        var motionSpeed: Double?
        var spinSpeed: Double?
        var surfaceOnly: Bool?

        fileprivate mutating func apply(_ attribute: Attribute, in scope: String, line: Int) throws {
            switch attribute.name {
            case .renderDistance:
                guard renderDistance == nil else {
                    throw KeyframeProgramError.duplicateAttribute(
                        scope: scope,
                        attribute: attribute.name.rawValue,
                        line: line
                    )
                }
                renderDistance = try attribute.requirePositiveInt(line: line)
            case .lodNearDistance:
                guard lodNearDistance == nil else {
                    throw KeyframeProgramError.duplicateAttribute(
                        scope: scope,
                        attribute: attribute.name.rawValue,
                        line: line
                    )
                }
                lodNearDistance = try attribute.requirePositiveInt(line: line)
            case .lodStepDistance:
                guard lodStepDistance == nil else {
                    throw KeyframeProgramError.duplicateAttribute(
                        scope: scope,
                        attribute: attribute.name.rawValue,
                        line: line
                    )
                }
                lodStepDistance = try attribute.requirePositiveInt(line: line)
            case .motionSpeed:
                guard motionSpeed == nil else {
                    throw KeyframeProgramError.duplicateAttribute(
                        scope: scope,
                        attribute: attribute.name.rawValue,
                        line: line
                    )
                }
                motionSpeed = try attribute.requirePositiveDouble(line: line)
            case .spinSpeed:
                guard spinSpeed == nil else {
                    throw KeyframeProgramError.duplicateAttribute(
                        scope: scope,
                        attribute: attribute.name.rawValue,
                        line: line
                    )
                }
                spinSpeed = try attribute.requirePositiveDouble(line: line)
            case .surfaceOnly:
                guard surfaceOnly == nil else {
                    throw KeyframeProgramError.duplicateAttribute(
                        scope: scope,
                        attribute: attribute.name.rawValue,
                        line: line
                    )
                }
                surfaceOnly = try attribute.requireBoolean(line: line)
            }
        }

        func resolved(overriding base: Attributes, line: Int) throws -> ResolvedAttributes {
            guard let renderDistance = renderDistance ?? base.renderDistance else {
                throw KeyframeProgramError.missingRequiredAttribute(
                    attribute: AttributeName.renderDistance.rawValue,
                    line: line
                )
            }
            guard let lodNearDistance = lodNearDistance ?? base.lodNearDistance else {
                throw KeyframeProgramError.missingRequiredAttribute(
                    attribute: AttributeName.lodNearDistance.rawValue,
                    line: line
                )
            }
            guard let lodStepDistance = lodStepDistance ?? base.lodStepDistance else {
                throw KeyframeProgramError.missingRequiredAttribute(
                    attribute: AttributeName.lodStepDistance.rawValue,
                    line: line
                )
            }
            return ResolvedAttributes(
                renderDistance: renderDistance,
                lodNearDistance: lodNearDistance,
                lodStepDistance: lodStepDistance,
                motionSpeed: motionSpeed ?? base.motionSpeed ?? 1.0,
                spinSpeed: spinSpeed ?? base.spinSpeed ?? 10.0,
                surfaceOnly: surfaceOnly ?? base.surfaceOnly ?? false
            )
        }
    }

    struct ResolvedAttributes {
        let renderDistance: Int
        let lodNearDistance: Int
        let lodStepDistance: Int
        let motionSpeed: Double
        let spinSpeed: Double
        let surfaceOnly: Bool
    }

    struct Scene {
        enum Location {
            case absolute(seed: Int64, anchor: SIMD3<Double>)
            case waypoint(name: String, offset: SIMD3<Double>)
        }

        let index: Int
        let location: Location
        let attributes: Attributes
        let keyframes: [Statement]
        let line: Int
    }

    struct Template {
        let name: String
        let keyframes: [Statement]
        let line: Int
    }

    enum Statement {
        case position(PositionKeyframe)
        case spin(SpinKeyframe)
        case invokeTemplate(TemplateInvocation)

        var line: Int {
            switch self {
            case .position(let keyframe):
                return keyframe.line
            case .spin(let keyframe):
                return keyframe.line
            case .invokeTemplate(let invocation):
                return invocation.line
            }
        }
    }

    struct PositionKeyframe {
        let offset: SIMD3<Double>
        let rotation: Rotation?
        let line: Int
    }

    struct SpinKeyframe {
        let deltaYawDegrees: Double
        let deltaPitchDegrees: Double
        let from: Rotation?
        let speedDegreesPerSecond: Double?
        let line: Int
    }

    struct TemplateInvocation {
        let name: String
        let line: Int
    }

    struct Rotation {
        let yawRadians: Float
        let pitchRadians: Float

        init(yawDegrees: Double, pitchDegrees: Double) {
            yawRadians = Float(yawDegrees * .pi / 180.0)
            pitchRadians = Float(pitchDegrees * .pi / 180.0)
        }
    }

    let attributes: Attributes
    let scenes: [Scene]
    let templates: [String: Template]
}

enum KeyframeProgramError: Error, CustomStringConvertible {
    case fileReadFailed(String)
    case unterminatedBlockComment(line: Int)
    case missingProgramHeader
    case duplicateProgramHeader(line: Int)
    case invalidSyntax(line: Int, reason: String)
    case duplicateAttribute(scope: String, attribute: String, line: Int)
    case invalidAttributeValue(attribute: String, value: String, line: Int, reason: String)
    case duplicateSceneIndex(Int, line: Int)
    case noScenes
    case duplicateTemplate(String, line: Int)
    case emptyScene(index: Int, line: Int)
    case emptyTemplate(name: String, line: Int)
    case missingRequiredAttribute(attribute: String, line: Int)
    case unknownTemplate(String, line: Int)
    case unknownWaypoint(String, line: Int)
    case templateCycle([String], line: Int)
    case missingInitialRotation(line: Int)
    case missingInitialPosition(line: Int)
    case invalidPitchRange(line: Int)

    var description: String {
        switch self {
        case .fileReadFailed(let name):
            return "failed to read keyframe program '\(name)'"
        case .unterminatedBlockComment(let line):
            return "unterminated block comment starting on line \(line)"
        case .missingProgramHeader:
            return "missing PROGRAM header"
        case .duplicateProgramHeader(let line):
            return "duplicate PROGRAM header on line \(line)"
        case .invalidSyntax(let line, let reason):
            return "invalid keyframe program syntax on line \(line): \(reason)"
        case .duplicateAttribute(let scope, let attribute, let line):
            return "duplicate attribute '\(attribute)' in \(scope) on line \(line)"
        case .invalidAttributeValue(let attribute, let value, let line, let reason):
            return "invalid value '\(value)' for attribute '\(attribute)' on line \(line): \(reason)"
        case .duplicateSceneIndex(let index, let line):
            return "duplicate scene index \(index) on line \(line)"
        case .noScenes:
            return "keyframe program must declare at least one scene"
        case .duplicateTemplate(let name, let line):
            return "duplicate template '\(name)' on line \(line)"
        case .emptyScene(let index, let line):
            return "scene \(index) on line \(line) must contain at least one keyframe"
        case .emptyTemplate(let name, let line):
            return "template '\(name)' on line \(line) must contain at least one keyframe"
        case .missingRequiredAttribute(let attribute, let line):
            return "missing required attribute '\(attribute)' for scene starting on line \(line)"
        case .unknownTemplate(let name, let line):
            return "unknown template '\(name)' referenced on line \(line)"
        case .unknownWaypoint(let name, let line):
            return "unknown waypoint '\(name)' referenced on line \(line)"
        case .templateCycle(let names, let line):
            return "template cycle detected on line \(line): \(names.joined(separator: " -> "))"
        case .missingInitialRotation(let line):
            return "first effective position keyframe must include rotation (line \(line))"
        case .missingInitialPosition(let line):
            return "keyframe sequence must establish a position before line \(line)"
        case .invalidPitchRange(let line):
            return "pitch must stay within [-90, +90] degrees (line \(line))"
        }
    }
}

private enum AttributeName: String {
    case renderDistance = "RENDER-DISTANCE"
    case lodNearDistance = "LOD-NEAR-DISTANCE"
    case lodStepDistance = "LOD-STEP-DISTANCE"
    case motionSpeed = "MOTION-SPEED"
    case spinSpeed = "SPIN-SPEED"
    case surfaceOnly = "SURFACE-ONLY"
}

private struct Attribute {
    let name: AttributeName
    let rawValue: String

    func requirePositiveInt(line: Int) throws -> Int {
        guard let value = Int(rawValue) else {
            throw KeyframeProgramError.invalidAttributeValue(
                attribute: name.rawValue,
                value: rawValue,
                line: line,
                reason: "expected a positive integer"
            )
        }
        guard value > 0 else {
            throw KeyframeProgramError.invalidAttributeValue(
                attribute: name.rawValue,
                value: rawValue,
                line: line,
                reason: "value must be greater than zero"
            )
        }
        return value
    }

    func requirePositiveDouble(line: Int) throws -> Double {
        guard let value = Double(rawValue) else {
            throw KeyframeProgramError.invalidAttributeValue(
                attribute: name.rawValue,
                value: rawValue,
                line: line,
                reason: "expected a real number"
            )
        }
        guard value > 0 else {
            throw KeyframeProgramError.invalidAttributeValue(
                attribute: name.rawValue,
                value: rawValue,
                line: line,
                reason: "value must be greater than zero"
            )
        }
        return value
    }

    func requireBoolean(line: Int) throws -> Bool {
        switch rawValue.lowercased() {
        case "true":
            return true;
        case "false":
            return false;
        default:
            throw KeyframeProgramError.invalidAttributeValue(
                attribute: name.rawValue,
                value: rawValue,
                line: line,
                reason: "value must be true or false"
            )
        }
    }
}

private struct ParsedLine {
    let lineNumber: Int
    let text: String
}

private enum KeyframeProgramBlock {
    case scene(
        index: Int,
        location: KeyframeProgram.Scene.Location,
        attributes: KeyframeProgram.Attributes,
        line: Int,
        keyframes: [KeyframeProgram.Statement]
    )
    case template(name: String, line: Int, keyframes: [KeyframeProgram.Statement])
}

struct CompiledKeyframeProgram {
    struct Scene {
        let index: Int
        let seed: Int64
        let settings: KeyframeProgram.ResolvedAttributes
        let anchor: SIMD3<Double>
        fileprivate let statements: [KeyframeProgram.Statement]

        func makePath(renderer: TerrainRenderer) throws -> TerrainRenderer.CinematicPath {
            try KeyframeProgramCompiler.compileScenePath(
                statements: statements,
                anchor: anchor,
                settings: settings,
                renderer: renderer
            )
        }
    }

    let scenes: [Scene]
}

enum KeyframeProgramLoader {
    static func load(from fileURL: URL, displayName: String) throws -> KeyframeProgram {
        let contents: String
        do {
            contents = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw KeyframeProgramError.fileReadFailed(displayName)
        }

        let strippedContents = try stripComments(from: contents)
        return try parse(strippedContents)
    }

    private static func stripComments(from source: String) throws -> String {
        enum State {
            case normal
            case lineComment
            case blockComment(startLine: Int)
        }

        var result = ""
        result.reserveCapacity(source.count)

        var state = State.normal
        var iterator = source.makeIterator()
        var bufferedCharacter: Character?
        var line = 1

        func nextCharacter() -> Character? {
            if let bufferedCharacter {
                return bufferedCharacter
            }
            return iterator.next()
        }

        func consumeCharacter() {
            bufferedCharacter = iterator.next()
        }

        bufferedCharacter = iterator.next()
        while let character = nextCharacter() {
            switch state {
            case .normal:
                if character == "/" {
                    consumeCharacter()
                    if let next = nextCharacter() {
                        if next == "/" {
                            result.append("  ")
                            consumeCharacter()
                            state = .lineComment
                            continue
                        }
                        if next == "*" {
                            result.append("  ")
                            consumeCharacter()
                            state = .blockComment(startLine: line)
                            continue
                        }
                    }
                    result.append(character)
                    continue
                }

                result.append(character)
                if character == "\n" {
                    line += 1
                }
                consumeCharacter()
            case .lineComment:
                if character == "\n" {
                    result.append("\n")
                    line += 1
                    state = .normal
                } else {
                    result.append(" ")
                }
                consumeCharacter()
            case .blockComment(let startLine):
                if character == "*" {
                    consumeCharacter()
                    if let next = nextCharacter(), next == "/" {
                        result.append("  ")
                        consumeCharacter()
                        state = .normal
                        continue
                    }
                    result.append(" ")
                    continue
                }

                if character == "\n" {
                    result.append("\n")
                    line += 1
                } else {
                    result.append(" ")
                }
                consumeCharacter()

                if bufferedCharacter == nil {
                    throw KeyframeProgramError.unterminatedBlockComment(line: startLine)
                }
            }
        }

        if case .blockComment(let startLine) = state {
            throw KeyframeProgramError.unterminatedBlockComment(line: startLine)
        }

        return result
    }

    private static func parse(_ source: String) throws -> KeyframeProgram {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let parsedLines = lines.enumerated().compactMap { index, rawLine -> ParsedLine? in
            let lineNumber = index + 1
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                return nil
            }
            return ParsedLine(lineNumber: lineNumber, text: line)
        }

        var programAttributes: KeyframeProgram.Attributes?
        var scenes: [KeyframeProgram.Scene] = []
        var templates: [String: KeyframeProgram.Template] = [:]
        var sceneIndexes: Set<Int> = []

        func finish(block: KeyframeProgramBlock) throws {
            switch block {
            case .scene(let index, let location, let attributes, let line, let keyframes):
                guard !keyframes.isEmpty else {
                    throw KeyframeProgramError.emptyScene(index: index, line: line)
                }
                guard sceneIndexes.insert(index).inserted else {
                    throw KeyframeProgramError.duplicateSceneIndex(index, line: line)
                }
                scenes.append(
                    KeyframeProgram.Scene(
                        index: index,
                        location: location,
                        attributes: attributes,
                        keyframes: keyframes,
                        line: line
                    )
                )
            case .template(let name, let line, let keyframes):
                guard !keyframes.isEmpty else {
                    throw KeyframeProgramError.emptyTemplate(name: name, line: line)
                }
                guard templates[name] == nil else {
                    throw KeyframeProgramError.duplicateTemplate(name, line: line)
                }
                templates[name] = KeyframeProgram.Template(name: name, keyframes: keyframes, line: line)
            }
        }

        var currentBlock: KeyframeProgramBlock?
        for parsedLine in parsedLines {
            let tokens = parsedLine.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let firstToken = tokens.first else {
                continue
            }

            if firstToken == "PROGRAM" {
                if let activeBlock = currentBlock {
                    try finish(block: activeBlock)
                    currentBlock = nil
                }
                guard programAttributes == nil else {
                    throw KeyframeProgramError.duplicateProgramHeader(line: parsedLine.lineNumber)
                }
                programAttributes = try parseProgramHeader(tokens: tokens, line: parsedLine.lineNumber)
                continue
            }

            if firstToken == "SCENE" {
                if let activeBlock = currentBlock {
                    try finish(block: activeBlock)
                    currentBlock = nil
                }
                currentBlock = try parseSceneHeader(tokens: tokens, line: parsedLine.lineNumber)
                continue
            }

            if firstToken == "TEMPLATE" {
                if let activeBlock = currentBlock {
                    try finish(block: activeBlock)
                    currentBlock = nil
                }
                currentBlock = try parseTemplateHeader(tokens: tokens, line: parsedLine.lineNumber)
                continue
            }

            guard let block = currentBlock else {
                throw KeyframeProgramError.invalidSyntax(
                    line: parsedLine.lineNumber,
                    reason: "expected PROGRAM, SCENE, or TEMPLATE header"
                )
            }
            let statement = try parseStatement(tokens: tokens, line: parsedLine.lineNumber)
            switch block {
            case .scene(let index, let location, let attributes, let line, var keyframes):
                keyframes.append(statement)
                currentBlock = .scene(
                    index: index,
                    location: location,
                    attributes: attributes,
                    line: line,
                    keyframes: keyframes
                )
            case .template(let name, let line, var keyframes):
                keyframes.append(statement)
                currentBlock = .template(name: name, line: line, keyframes: keyframes)
            }
        }

        if let currentBlock {
            try finish(block: currentBlock)
        }

        guard let attributes = programAttributes else {
            throw KeyframeProgramError.missingProgramHeader
        }
        guard !scenes.isEmpty else {
            throw KeyframeProgramError.noScenes
        }

        return KeyframeProgram(attributes: attributes, scenes: scenes, templates: templates)
    }

    private static func parseProgramHeader(tokens: [String], line: Int) throws -> KeyframeProgram.Attributes {
        guard !tokens.isEmpty, tokens[0] == "PROGRAM" else {
            throw KeyframeProgramError.invalidSyntax(
                line: line,
                reason: "PROGRAM header must be 'PROGRAM [WITH <attribute> <value>] ...'"
            )
        }
        return try parseHeaderAttributes(tokens: Array(tokens.dropFirst()), scope: "program", line: line)
    }

    private static func parseSceneHeader(tokens: [String], line: Int) throws -> KeyframeProgramBlock {
        guard tokens.count >= 4 else {
            throw KeyframeProgramError.invalidSyntax(
                line: line,
                reason: "SCENE header is incomplete"
            )
        }
        let index = try parseNonNegativeInt(tokens[1], line: line, label: "scene index")
        let location: KeyframeProgram.Scene.Location
        let attributesStartIndex: Int

        if tokens[2] == "SEED" {
            guard tokens.count >= 8, tokens[4] == "AT-POSITION" else {
                throw KeyframeProgramError.invalidSyntax(
                    line: line,
                    reason: "SCENE header must be 'SCENE <index> SEED <seed> AT-POSITION <x> <y> <z> [WITH ...]' or 'SCENE <index> WAYPOINT <waypoint> [OFFSET <dx> <dy> <dz>] [WITH ...]'"
                )
            }
            let seed = try parseSeed(tokens[3], line: line)
            let anchor = try parseVector3(tokens[5], tokens[6], tokens[7], line: line, label: "scene anchor")
            location = .absolute(seed: seed, anchor: anchor)
            attributesStartIndex = 8
        } else if tokens[2] == "WAYPOINT" {
            guard tokens.count >= 4 else {
                throw KeyframeProgramError.invalidSyntax(
                    line: line,
                    reason: "SCENE waypoint header is incomplete"
                )
            }
            let waypointName = tokens[3]
            var offset = SIMD3<Double>(repeating: 0)
            var indexAfterLocation = 4
            if tokens.count > indexAfterLocation, tokens[indexAfterLocation] == "OFFSET" {
                guard tokens.count >= indexAfterLocation + 4 else {
                    throw KeyframeProgramError.invalidSyntax(
                        line: line,
                        reason: "OFFSET must be 'OFFSET <delta-x> <delta-y> <delta-z>'"
                    )
                }
                offset = try parseVector3(
                    tokens[indexAfterLocation + 1],
                    tokens[indexAfterLocation + 2],
                    tokens[indexAfterLocation + 3],
                    line: line,
                    label: "scene waypoint offset"
                )
                indexAfterLocation += 4
            }
            location = .waypoint(name: waypointName, offset: offset)
            attributesStartIndex = indexAfterLocation
        } else {
            throw KeyframeProgramError.invalidSyntax(
                line: line,
                reason: "SCENE header must be 'SCENE <index> SEED <seed> AT-POSITION <x> <y> <z> [WITH ...]' or 'SCENE <index> WAYPOINT <waypoint> [OFFSET <dx> <dy> <dz>] [WITH ...]'"
            )
        }

        let attributes: KeyframeProgram.Attributes
        if tokens.count == attributesStartIndex {
            attributes = KeyframeProgram.Attributes()
        } else {
            attributes = try parseHeaderAttributes(
                tokens: Array(tokens[attributesStartIndex...]),
                scope: "scene \(index)",
                line: line
            )
        }
        return .scene(
            index: index,
            location: location,
            attributes: attributes,
            line: line,
            keyframes: []
        )
    }

    private static func parseTemplateHeader(tokens: [String], line: Int) throws -> KeyframeProgramBlock {
        guard tokens.count == 2 else {
            throw KeyframeProgramError.invalidSyntax(
                line: line,
                reason: "TEMPLATE header must be 'TEMPLATE <template-name>'"
            )
        }
        return .template(name: tokens[1], line: line, keyframes: [])
    }

    private static func parseAttributes(tokens: [String], scope: String, line: Int) throws -> KeyframeProgram.Attributes {
        guard tokens.count.isMultiple(of: 2) else {
            throw KeyframeProgramError.invalidSyntax(
                line: line,
                reason: "attribute list must contain <attribute> <value> pairs"
            )
        }
        var attributes = KeyframeProgram.Attributes()
        for pairStart in stride(from: 0, to: tokens.count, by: 2) {
            let attributeName = tokens[pairStart]
            guard let name = AttributeName(rawValue: attributeName) else {
                throw KeyframeProgramError.invalidSyntax(
                    line: line,
                    reason: "unknown attribute '\(attributeName)'"
                )
            }
            try attributes.apply(
                Attribute(name: name, rawValue: tokens[pairStart + 1]),
                in: scope,
                line: line
            )
        }
        return attributes
    }

    private static func parseHeaderAttributes(tokens: [String], scope: String, line: Int) throws -> KeyframeProgram.Attributes {
        guard !tokens.isEmpty else {
            return KeyframeProgram.Attributes()
        }

        var normalizedTokens: [String] = []
        normalizedTokens.reserveCapacity(tokens.count)

        var index = 0
        while index < tokens.count {
            if tokens[index] == "WITH" {
                index += 1
                guard index < tokens.count else {
                    throw KeyframeProgramError.invalidSyntax(
                        line: line,
                        reason: "WITH must be followed by <attribute> <value>"
                    )
                }
            }

            guard index + 1 < tokens.count else {
                throw KeyframeProgramError.invalidSyntax(
                    line: line,
                    reason: "attribute list must contain <attribute> <value> pairs"
                )
            }

            normalizedTokens.append(tokens[index])
            normalizedTokens.append(tokens[index + 1])
            index += 2
        }

        return try parseAttributes(tokens: normalizedTokens, scope: scope, line: line)
    }

    private static func parseStatement(tokens: [String], line: Int) throws -> KeyframeProgram.Statement {
        guard let firstToken = tokens.first else {
            throw KeyframeProgramError.invalidSyntax(line: line, reason: "empty statement")
        }

        switch firstToken {
        case "POSITION":
            return .position(try parsePositionKeyframe(tokens: tokens, line: line))
        case "SPIN":
            return .spin(try parseSpinKeyframe(tokens: tokens, line: line))
        case "INVOKE-TEMPLATE":
            guard tokens.count == 2 else {
                throw KeyframeProgramError.invalidSyntax(
                    line: line,
                    reason: "INVOKE-TEMPLATE must be 'INVOKE-TEMPLATE <template-name>'"
                )
            }
            return .invokeTemplate(.init(name: tokens[1], line: line))
        default:
            throw KeyframeProgramError.invalidSyntax(
                line: line,
                reason: "unknown keyframe keyword '\(firstToken)'"
            )
        }
    }

    private static func parsePositionKeyframe(tokens: [String], line: Int) throws -> KeyframeProgram.PositionKeyframe {
        guard tokens.count == 4 || tokens.count == 7 else {
            throw KeyframeProgramError.invalidSyntax(
                line: line,
                reason: "POSITION must be 'POSITION <x> <y> <z> [ROTATION <yaw> <pitch>]'"
            )
        }
        let offset = try parseVector3(tokens[1], tokens[2], tokens[3], line: line, label: "position")
        let rotation: KeyframeProgram.Rotation?
        if tokens.count == 4 {
            rotation = nil
        } else {
            guard tokens[4] == "ROTATION" else {
                throw KeyframeProgramError.invalidSyntax(
                    line: line,
                    reason: "POSITION rotation clause must be 'ROTATION <yaw> <pitch>'"
                )
            }
            rotation = try parseRotation(yawToken: tokens[5], pitchToken: tokens[6], line: line)
        }
        return .init(offset: offset, rotation: rotation, line: line)
    }

    private static func parseSpinKeyframe(tokens: [String], line: Int) throws -> KeyframeProgram.SpinKeyframe {
        guard tokens.count == 3 || tokens.count == 6 || tokens.count == 5 || tokens.count == 8 else {
            throw KeyframeProgramError.invalidSyntax(
                line: line,
                reason: "SPIN must be 'SPIN <delta-yaw> <delta-pitch> [FROM <yaw> <pitch>] [SPEED <degrees-per-second>]'"
            )
        }

        let deltaYawDegrees = try parseDouble(tokens[1], line: line, label: "spin yaw delta")
        let deltaPitchDegrees = try parseDouble(tokens[2], line: line, label: "spin pitch delta")

        var index = 3
        var from: KeyframeProgram.Rotation?
        var speedDegreesPerSecond: Double?
        while index < tokens.count {
            switch tokens[index] {
            case "FROM":
                guard from == nil, index + 2 < tokens.count else {
                    throw KeyframeProgramError.invalidSyntax(
                        line: line,
                        reason: "invalid FROM clause in SPIN"
                    )
                }
                from = try parseRotation(yawToken: tokens[index + 1], pitchToken: tokens[index + 2], line: line)
                index += 3
            case "SPEED":
                guard speedDegreesPerSecond == nil, index + 1 < tokens.count else {
                    throw KeyframeProgramError.invalidSyntax(
                        line: line,
                        reason: "invalid SPEED clause in SPIN"
                    )
                }
                let speed = try parseDouble(tokens[index + 1], line: line, label: "spin speed")
                guard speed > 0 else {
                    throw KeyframeProgramError.invalidSyntax(
                        line: line,
                        reason: "spin speed must be greater than zero"
                    )
                }
                speedDegreesPerSecond = speed
                index += 2
            default:
                throw KeyframeProgramError.invalidSyntax(
                    line: line,
                    reason: "unexpected token '\(tokens[index])' in SPIN"
                )
            }
        }

        return .init(
            deltaYawDegrees: deltaYawDegrees,
            deltaPitchDegrees: deltaPitchDegrees,
            from: from,
            speedDegreesPerSecond: speedDegreesPerSecond,
            line: line
        )
    }

    private static func parseRotation(yawToken: String, pitchToken: String, line: Int) throws -> KeyframeProgram.Rotation {
        let yawDegrees = try parseDouble(yawToken, line: line, label: "yaw")
        let pitchDegrees = try parseDouble(pitchToken, line: line, label: "pitch")
        guard pitchDegrees >= -90, pitchDegrees <= 90 else {
            throw KeyframeProgramError.invalidPitchRange(line: line)
        }
        return .init(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees)
    }

    private static func parseVector3(
        _ xToken: String,
        _ yToken: String,
        _ zToken: String,
        line: Int,
        label: String
    ) throws -> SIMD3<Double> {
        SIMD3<Double>(
            try parseDouble(xToken, line: line, label: "\(label) x"),
            try parseDouble(yToken, line: line, label: "\(label) y"),
            try parseDouble(zToken, line: line, label: "\(label) z")
        )
    }

    private static func parseNonNegativeInt(_ token: String, line: Int, label: String) throws -> Int {
        guard let value = Int(token) else {
            throw KeyframeProgramError.invalidSyntax(
                line: line,
                reason: "expected \(label) to be an integer"
            )
        }
        guard value >= 0 else {
            throw KeyframeProgramError.invalidSyntax(
                line: line,
                reason: "\(label) must be greater than or equal to zero"
            )
        }
        return value
    }

    private static func parseSeed(_ token: String, line: Int) throws -> Int64 {
        guard let value = Int64(token) else {
            throw KeyframeProgramError.invalidSyntax(
                line: line,
                reason: "expected seed to be a signed 64-bit integer"
            )
        }
        return value
    }

    private static func parseDouble(_ token: String, line: Int, label: String) throws -> Double {
        guard let value = Double(token) else {
            throw KeyframeProgramError.invalidSyntax(
                line: line,
                reason: "expected \(label) to be a real number"
            )
        }
        return value
    }
}

enum KeyframeProgramCompiler {
    private static let spinInterpolationLimitRadians = Double.pi / 2.0

    static func compile(_ program: KeyframeProgram) throws -> CompiledKeyframeProgram {
        try compile(program) { scene in
            switch scene.location {
            case .absolute(let seed, let anchor):
                return (seed, anchor)
            case .waypoint(let name, _):
                throw KeyframeProgramError.unknownWaypoint(name, line: scene.line)
            }
        }
    }

    static func compile(
        _ program: KeyframeProgram,
        resolveSceneLocation: (KeyframeProgram.Scene) throws -> (seed: Int64, anchor: SIMD3<Double>)
    ) throws -> CompiledKeyframeProgram {
        var compiledScenes: [CompiledKeyframeProgram.Scene] = []
        let sortedScenes = program.scenes.sorted { lhs, rhs in
            if lhs.index == rhs.index {
                return lhs.line < rhs.line
            }
            return lhs.index < rhs.index
        }

        for scene in sortedScenes {
            let resolvedLocation = try resolveSceneLocation(scene)
            let settings = try scene.attributes.resolved(overriding: program.attributes, line: scene.line)
            let expanded = try expandStatements(
                in: scene,
                templates: program.templates
            )
            compiledScenes.append(
                .init(
                    index: scene.index,
                    seed: resolvedLocation.seed,
                    settings: settings,
                    anchor: resolvedLocation.anchor,
                    statements: expanded
                )
            )
        }

        return CompiledKeyframeProgram(scenes: compiledScenes)
    }

    private static func expandStatements(
        in scene: KeyframeProgram.Scene,
        templates: [String: KeyframeProgram.Template]
    ) throws -> [KeyframeProgram.Statement] {
        try expand(scene.keyframes, templates: templates, visiting: [])
    }

    private static func expand(
        _ statements: [KeyframeProgram.Statement],
        templates: [String: KeyframeProgram.Template],
        visiting: [String]
    ) throws -> [KeyframeProgram.Statement] {
        var expanded: [KeyframeProgram.Statement] = []
        for statement in statements {
            switch statement {
            case .position, .spin:
                expanded.append(statement)
            case .invokeTemplate(let invocation):
                guard let template = templates[invocation.name] else {
                    throw KeyframeProgramError.unknownTemplate(invocation.name, line: invocation.line)
                }
                if let cycleIndex = visiting.firstIndex(of: invocation.name) {
                    let cycle = Array(visiting[cycleIndex...]) + [invocation.name]
                    throw KeyframeProgramError.templateCycle(cycle, line: invocation.line)
                }
                expanded.append(
                    contentsOf: try expand(
                        template.keyframes,
                        templates: templates,
                        visiting: visiting + [invocation.name]
                    )
                )
            }
        }
        return expanded
    }

    fileprivate static func compileScenePath(
        statements: [KeyframeProgram.Statement],
        anchor: SIMD3<Double>,
        settings: KeyframeProgram.ResolvedAttributes,
        renderer: TerrainRenderer
    ) throws -> TerrainRenderer.CinematicPath {
        var samples: [TerrainRenderer.CinematicPathSample] = []
        var preloadPositions: [SIMD3<Double>] = []
        var currentTime = 0.0
        var currentPose: TerrainRenderer.Keyframe?
        var pendingPositionKeyframes: [TerrainRenderer.Keyframe] = []
        var pendingPositionLine: Int?
        var pendingPositionStartPose: TerrainRenderer.Keyframe?

        func appendSampleIfNeeded(_ sample: TerrainRenderer.CinematicPathSample) {
            if let last = samples.last,
               sample.timeFromStart == last.timeFromStart,
               sample.position == last.position,
               sample.yaw == last.yaw,
               sample.pitch == last.pitch {
                return
            }
            samples.append(sample)
        }

        func flushPendingPositions() {
            guard !pendingPositionKeyframes.isEmpty else {
                return
            }
            let playbackKeyframes: [TerrainRenderer.Keyframe]
            if let pendingPositionStartPose {
                playbackKeyframes = [pendingPositionStartPose] + pendingPositionKeyframes
            } else {
                playbackKeyframes = pendingPositionKeyframes
            }

            if playbackKeyframes.count == 1 {
                let keyframe = playbackKeyframes[0]
                appendSampleIfNeeded(
                    TerrainRenderer.CinematicPathSample(
                        position: keyframe.position,
                        yaw: keyframe.yaw,
                        pitch: keyframe.pitch,
                        timeFromStart: currentTime
                    )
                )
            } else {
                let path = renderer.buildCinematicPath(from: playbackKeyframes, playbackSpeed: settings.motionSpeed)
                for (index, sample) in path.samples.enumerated() {
                    if !samples.isEmpty, index == 0 {
                        continue
                    }
                    appendSampleIfNeeded(
                        TerrainRenderer.CinematicPathSample(
                            position: sample.position,
                            yaw: sample.yaw,
                            pitch: sample.pitch,
                            timeFromStart: sample.timeFromStart + currentTime
                        )
                    )
                }
                currentTime += path.totalDuration
            }
            pendingPositionKeyframes.removeAll(keepingCapacity: true)
            pendingPositionLine = nil
            pendingPositionStartPose = nil
        }

        for statement in statements {
            switch statement {
            case .position(let keyframe):
                let rotation: KeyframeProgram.Rotation
                if let explicitRotation = keyframe.rotation {
                    rotation = explicitRotation
                } else if let currentPose {
                    rotation = .init(
                        yawDegrees: Double(currentPose.yaw) * 180.0 / .pi,
                        pitchDegrees: Double(currentPose.pitch) * 180.0 / .pi
                    )
                } else {
                    throw KeyframeProgramError.missingInitialRotation(line: keyframe.line)
                }

                let absoluteKeyframe = TerrainRenderer.Keyframe(
                    position: anchor + keyframe.offset,
                    yaw: rotation.yawRadians,
                    pitch: rotation.pitchRadians
                )
                if pendingPositionKeyframes.isEmpty {
                    pendingPositionStartPose = currentPose
                }
                pendingPositionKeyframes.append(absoluteKeyframe)
                preloadPositions.append(absoluteKeyframe.position)
                pendingPositionLine = pendingPositionLine ?? keyframe.line
                currentPose = absoluteKeyframe
            case .spin(let keyframe):
                flushPendingPositions()

                let startRotation: KeyframeProgram.Rotation
                let startPosition: SIMD3<Double>
                if let from = keyframe.from {
                    startPosition = currentPose?.position ?? anchor
                    startRotation = from
                } else if let poseBeforeSpin = currentPose {
                    startPosition = poseBeforeSpin.position
                    startRotation = .init(
                        yawDegrees: Double(poseBeforeSpin.yaw) * 180.0 / .pi,
                        pitchDegrees: Double(poseBeforeSpin.pitch) * 180.0 / .pi
                    )
                } else {
                    startPosition = anchor
                    startRotation = .init(
                        yawDegrees: 0,
                        pitchDegrees: 0
                    )
                }
                preloadPositions.append(startPosition)

                let startYawRadians = Double(startRotation.yawRadians)
                let startPitchRadians = Double(startRotation.pitchRadians)
                let deltaYawRadians = keyframe.deltaYawDegrees * .pi / 180.0
                let deltaPitchRadians = keyframe.deltaPitchDegrees * .pi / 180.0
                let endPitchRadians = startPitchRadians + deltaPitchRadians
                guard startPitchRadians >= -Double.pi / 2.0,
                      startPitchRadians <= Double.pi / 2.0,
                      endPitchRadians >= -Double.pi / 2.0,
                      endPitchRadians <= Double.pi / 2.0 else {
                    throw KeyframeProgramError.invalidPitchRange(line: keyframe.line)
                }

                appendSampleIfNeeded(
                    TerrainRenderer.CinematicPathSample(
                        position: startPosition,
                        yaw: Float(startYawRadians),
                        pitch: Float(startPitchRadians),
                        timeFromStart: currentTime
                    )
                )

                let spinSpeed = keyframe.speedDegreesPerSecond ?? settings.spinSpeed
                let duration = hypot(keyframe.deltaYawDegrees, keyframe.deltaPitchDegrees) / spinSpeed
                let maxDeltaRadians = max(abs(deltaYawRadians), abs(deltaPitchRadians))
                let segmentCount = max(1, Int(ceil(maxDeltaRadians / spinInterpolationLimitRadians)))

                for segmentIndex in 1...segmentCount {
                    let t = Double(segmentIndex) / Double(segmentCount)
                    let segmentYaw = startYawRadians + deltaYawRadians * t
                    let segmentPitch = startPitchRadians + deltaPitchRadians * t
                    appendSampleIfNeeded(
                        TerrainRenderer.CinematicPathSample(
                            position: startPosition,
                            yaw: Float(segmentYaw),
                            pitch: Float(segmentPitch),
                            timeFromStart: currentTime + duration * t
                        )
                    )
                }

                currentTime += duration
                currentPose = TerrainRenderer.Keyframe(
                    position: startPosition,
                    yaw: Float(startYawRadians + deltaYawRadians),
                    pitch: Float(endPitchRadians)
                )
            case .invokeTemplate:
                break
            }
        }

        flushPendingPositions()

        if samples.isEmpty, let currentPose, let line = pendingPositionLine {
            if currentPose.pitch < -Float.pi / 2.0 || currentPose.pitch > Float.pi / 2.0 {
                throw KeyframeProgramError.invalidPitchRange(line: line)
            }
            samples.append(
                TerrainRenderer.CinematicPathSample(
                    position: currentPose.position,
                    yaw: currentPose.yaw,
                    pitch: currentPose.pitch,
                    timeFromStart: 0
                )
            )
        }

        return TerrainRenderer.CinematicPath(
            samples: samples,
            totalDuration: samples.last?.timeFromStart ?? 0,
            preloadPositions: preloadPositions
        )
    }
}
