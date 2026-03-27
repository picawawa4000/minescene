import Foundation
import SwiftSDL
#if canImport(simd)
import simd
#endif

enum TerrainRendererCommandParseError: Error, CustomStringConvertible {
    case missingArgument(String)
    case invalidInt(String)
    case invalidDouble(String)
    case invalidWorldSeed(String)
    case invalidLocalFilepath(String)
    case invalidPosition(axis: String, value: String)
    case trailingArguments(String)
    case invalidArguments(String)

    var description: String {
        switch self {
        case .missingArgument(let expected):
            return "expected \(expected), but reached the end of the command"
        case .invalidInt(let value):
            return "expected integer argument, got '\(value)'"
        case .invalidDouble(let value):
            return "expected double argument, got '\(value)'"
        case .invalidWorldSeed(let value):
            return "invalid world seed '\(value)'; expected signed 64-bit integer"
        case .invalidLocalFilepath(let value):
            return "invalid local filepath '\(value)'; use a relative path without leading '/'"
        case .invalidPosition(let axis, let value):
            return "expected \(axis) coordinate, got '\(value)'"
        case .trailingArguments(let value):
            return "unexpected trailing arguments '\(value)'"
        case .invalidArguments(let message):
            return message
        }
    }
}

struct TerrainRendererCommandArgumentParser {
    private let tokens: [Substring]
    private var index = 0

    init(_ arguments: String) {
        self.tokens = arguments.split(whereSeparator: \.isWhitespace)
    }

    var remainingCount: Int {
        tokens.count - index
    }

    mutating func getNextInt() throws -> Int {
        let token = try nextToken(expected: "an integer")
        guard Self.isValidIntToken(token), let value = Int(token) else {
            throw TerrainRendererCommandParseError.invalidInt(token)
        }
        return value
    }

    mutating func getNextDouble() throws -> Double {
        let token = try nextToken(expected: "a double")
        guard let value = Self.parseStrictDouble(token) else {
            throw TerrainRendererCommandParseError.invalidDouble(token)
        }
        return value
    }

    mutating func getNextWorldSeed() throws -> Int64 {
        let token = try nextToken(expected: "a world seed")
        guard Self.isValidIntToken(token), let value = Int64(token) else {
            throw TerrainRendererCommandParseError.invalidWorldSeed(token)
        }
        return value
    }

    mutating func getNextLocalFilepath() throws -> String {
        let token = try nextToken(expected: "a local filepath")
        guard Self.isValidLocalFilepathToken(token) else {
            throw TerrainRendererCommandParseError.invalidLocalFilepath(token)
        }
        return token
    }

    mutating func getNextString() throws -> String {
        try nextToken(expected: "a string")
    }

    mutating func getNextPos(currentPosition: SIMD3<Double>) throws -> SIMD3<Double> {
        SIMD3<Double>(
            try parsePositionComponent(axis: "x", current: currentPosition.x),
            try parsePositionComponent(axis: "y", current: currentPosition.y),
            try parsePositionComponent(axis: "z", current: currentPosition.z)
        )
    }

    mutating func end() throws {
        guard index < tokens.count else {
            return
        }
        let trailing = tokens[index...].joined(separator: " ")
        throw TerrainRendererCommandParseError.trailingArguments(trailing)
    }

    private mutating func parsePositionComponent(axis: String, current: Double) throws -> Double {
        let token = try nextToken(expected: "\(axis) coordinate")
        if token == "~" {
            return current
        }
        if token.first == "~" {
            let offsetToken = String(token.dropFirst())
            guard let offset = Self.parseStrictDouble(offsetToken) else {
                throw TerrainRendererCommandParseError.invalidPosition(axis: axis, value: token)
            }
            return current + offset
        }
        guard let absolute = Self.parseStrictDouble(token) else {
            throw TerrainRendererCommandParseError.invalidPosition(axis: axis, value: token)
        }
        return absolute
    }

    private mutating func nextToken(expected: String) throws -> String {
        guard index < tokens.count else {
            throw TerrainRendererCommandParseError.missingArgument(expected)
        }
        let token = String(tokens[index])
        index += 1
        return token
    }

    private static func isValidIntToken(_ token: String) -> Bool {
        guard !token.isEmpty else {
            return false
        }
        let digits = token.first == "+" || token.first == "-"
            ? token.dropFirst()
            : token[...]
        guard !digits.isEmpty else {
            return false
        }
        return digits.allSatisfy(isASCIIDigit)
    }

    private static func parseStrictDouble(_ token: String) -> Double? {
        guard !token.isEmpty else {
            return nil
        }

        let unsigned = token.first == "+" || token.first == "-"
            ? String(token.dropFirst())
            : token
        guard !unsigned.isEmpty else {
            return nil
        }

        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else {
            return nil
        }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isASCIIDigit) }) else {
            return nil
        }

        return Double(token)
    }

    private static func isValidLocalFilepathToken(_ token: String) -> Bool {
        guard !token.isEmpty, !token.hasPrefix("/") else {
            return false
        }
        let components = token.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            return false
        }
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                return false
            }
        }
        return true
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }
}

struct TerrainRendererCommandLogEntry {
    let message: String
    let isError: Bool
    var age: Float = 0
}

extension TerrainRenderer {
    var isCommandPromptActive: Bool {
        commandPromptActive
    }

    func handleCommandPromptEvent(_ event: SDL_Event, window: OpaquePointer?) {
        switch event.eventType {
        case .keyDown:
            switch event.key.key {
            case SDLK_RETURN, SDLK_RETURN2:
                closeCommandPrompt(window: window, execute: true)
            case SDLK_UP:
                navigateCommandPromptHistory(direction: -1)
            case SDLK_DOWN:
                navigateCommandPromptHistory(direction: 1)
            case SDLK_BACKSPACE:
                beginEditingCommandPromptHistorySelectionIfNeeded()
                if !commandPromptText.isEmpty {
                    commandPromptText.removeLast()
                }
                commandPromptDraftText = commandPromptText
            case SDLK_ESCAPE:
                closeCommandPrompt(window: window, execute: false)
            default:
                break
            }
        case .textInput:
            if let textPointer = event.text.text {
                appendCommandPromptText(String(cString: textPointer))
            }
        default:
            break
        }
    }

    func openCommandPrompt(window: OpaquePointer?) {
        commandPromptActive = true
        commandPromptText = ""
        commandPromptDraftText = ""
        commandPromptHistoryIndex = nil
        commandPromptCursorElapsed = 0
        resetMovementKeys()
        if let window {
            _ = SDL_StartTextInput(window)
        }
    }

    func closeCommandPrompt(window: OpaquePointer?, execute: Bool) {
        if execute {
            executeCommand(commandPromptText)
        }
        commandPromptActive = false
        commandPromptText = ""
        commandPromptDraftText = ""
        commandPromptHistoryIndex = nil
        commandPromptCursorElapsed = 0
        if let window {
            _ = SDL_StopTextInput(window)
        }
    }

    func appendCommandPromptText(_ text: String) {
        let sanitized = String(
            text
                .unicodeScalars
                .filter { !CharacterSet.controlCharacters.contains($0) && $0.value != 0x7F }
        )
        guard !sanitized.isEmpty else {
            return
        }
        beginEditingCommandPromptHistorySelectionIfNeeded()
        commandPromptText += sanitized
        commandPromptDraftText = commandPromptText
    }

    func executeCommand(_ commandText: String) {
        let trimmedCommand = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            return
        }

        if commandPromptHistory.last != trimmedCommand {
            commandPromptHistory.append(trimmedCommand)
            if commandPromptHistory.count > 100 {
                commandPromptHistory.removeFirst(commandPromptHistory.count - 100)
            }
        }
        commandPromptDraftText = ""
        commandPromptHistoryIndex = nil

        let commandName: String
        let arguments: String
        if let firstWhitespace = trimmedCommand.firstIndex(where: \.isWhitespace) {
            commandName = String(trimmedCommand[..<firstWhitespace])
            arguments = String(trimmedCommand[firstWhitespace...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            commandName = trimmedCommand
            arguments = ""
        }

        let commandLabel = "/\(commandName)"

        do {
            switch commandName {
            case "tp":
                var parser = TerrainRendererCommandArgumentParser(arguments)
                let currentPosition = cameraPosition
                let targetPosition = try parser.getNextPos(currentPosition: currentPosition)
                try parser.end()
                cameraPosition = targetPosition
                logCommandMessage(
                    "Teleported to (\(formatCommandNumber(targetPosition.x)), \(formatCommandNumber(targetPosition.y)), \(formatCommandNumber(targetPosition.z)))"
                )
            default:
                if let externalCommandExecutor,
                   try externalCommandExecutor(commandName, arguments, self) {
                    return
                }
                logCommandMessage("Unknown command '\(commandLabel)'", isError: true)
            }
        } catch let error as TerrainRendererCommandParseError {
            logCommandMessage("Failed to parse '\(commandLabel)': \(error.description)", isError: true)
        } catch {
            logCommandMessage("Failed to execute '\(commandLabel)': \(error)", isError: true)
        }
    }

    func logCommandMessage(_ message: String, isError: Bool = false) {
        print(message)
        commandLogEntries.append(TerrainRendererCommandLogEntry(message: message, isError: isError))
        if commandLogEntries.count > 5 {
            commandLogEntries.removeFirst(commandLogEntries.count - 5)
        }
    }

    func formatCommandNumber(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        while text.contains(".") && text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }

    func currentCommandPromptDisplayText() -> String? {
        guard commandPromptActive else {
            return nil
        }
        return commandPromptText
    }

    func isCommandPromptCursorVisible() -> Bool {
        guard commandPromptActive else {
            return false
        }
        let phase = commandPromptCursorElapsed.truncatingRemainder(dividingBy: commandPromptCursorBlinkPeriod * 2)
        return phase < commandPromptCursorBlinkPeriod
    }

    private func navigateCommandPromptHistory(direction: Int) {
        guard !commandPromptHistory.isEmpty else {
            return
        }

        if commandPromptHistoryIndex == nil {
            commandPromptDraftText = commandPromptText
        }

        if direction < 0 {
            let nextIndex = max(0, (commandPromptHistoryIndex ?? commandPromptHistory.count) - 1)
            commandPromptHistoryIndex = nextIndex
            commandPromptText = commandPromptHistory[nextIndex]
        } else {
            let nextIndex = (commandPromptHistoryIndex ?? commandPromptHistory.count) + 1
            if nextIndex >= commandPromptHistory.count {
                commandPromptHistoryIndex = nil
                commandPromptText = commandPromptDraftText
            } else {
                commandPromptHistoryIndex = nextIndex
                commandPromptText = commandPromptHistory[nextIndex]
            }
        }
    }

    private func beginEditingCommandPromptHistorySelectionIfNeeded() {
        guard commandPromptHistoryIndex != nil else {
            return
        }
        commandPromptHistoryIndex = nil
        commandPromptDraftText = commandPromptText
    }
}
