import Foundation
import SwiftSDL

enum SettingError: Error, CustomStringConvertible {
    case unknownSetting(String)
    case invalidValue(setting: String, value: String, reason: String)

    var description: String {
        switch self {
        case .unknownSetting(let name):
            return "unknown setting '\(name)'"
        case .invalidValue(let setting, let value, let reason):
            return "invalid value '\(value)' for setting '\(setting)': \(reason)"
        }
    }
}

protocol SettingValueType {
    static var typeDescription: String { get }
    static func decode(from string: String) throws -> Self
    var encodedString: String { get }
    var displayString: String { get }
}

protocol SettingProtocol: AnyObject {
    var name: String { get }
    var summary: String { get }
    var defaultValueDescription: String { get }
    var currentValueDescription: String { get }
    func setValue(from string: String) throws
    func loadPersistedValue(from string: String) throws
    func persistedValueString() -> String
}

final class Setting<Value: SettingValueType>: SettingProtocol {
    let name: String
    let summary: String
    let defaultValue: Value

    private(set) var value: Value
    private let validator: ((Value) -> String?)?

    init(
        name: String,
        summary: String,
        defaultValue: Value,
        validator: ((Value) -> String?)? = nil
    ) {
        self.name = name
        self.summary = summary
        self.defaultValue = defaultValue
        self.value = defaultValue
        self.validator = validator
    }

    var defaultValueDescription: String {
        defaultValue.displayString
    }

    var currentValueDescription: String {
        value.displayString
    }

    func setValue(from string: String) throws {
        value = try decodeAndValidate(from: string)
    }

    func loadPersistedValue(from string: String) throws {
        value = try decodeAndValidate(from: string)
    }

    func persistedValueString() -> String {
        value.encodedString
    }

    private func validate(_ value: Value, rawValue: String) throws -> Value {
        if let validator, let reason = validator(value) {
            throw SettingError.invalidValue(setting: name, value: rawValue, reason: reason)
        }
        return value
    }

    private func decodeAndValidate(from string: String) throws -> Value {
        do {
            return try validate(Value.decode(from: string), rawValue: string)
        } catch let error as SettingError {
            switch error {
            case .unknownSetting:
                throw error
            case .invalidValue(_, _, let reason):
                throw SettingError.invalidValue(setting: name, value: string, reason: reason)
            }
        } catch {
            throw SettingError.invalidValue(setting: name, value: string, reason: String(describing: error))
        }
    }
}

struct IntSettingValue: SettingValueType {
    static let typeDescription = "integer"

    let value: Int

    static func decode(from string: String) throws -> Self {
        guard let value = Int(string) else {
            throw SettingError.invalidValue(setting: "<unknown>", value: string, reason: "expected integer")
        }
        return IntSettingValue(value: value)
    }

    var encodedString: String {
        String(value)
    }

    var displayString: String {
        encodedString
    }
}

struct KeybindSettingValue: SettingValueType {
    static let typeDescription = "key"

    let keycode: SDL_Keycode

    static func decode(from string: String) throws -> Self {
        let normalized = normalizeKeyToken(string)
        if let aliasedKeycode = aliasToKeycode[normalized] {
            return KeybindSettingValue(keycode: aliasedKeycode)
        }
        let keycode = string.withCString { SDL_GetKeyFromName($0) }
        if keycode != SDLK_UNKNOWN {
            return KeybindSettingValue(keycode: keycode)
        }
        throw SettingError.invalidValue(setting: "<unknown>", value: string, reason: "expected key name")
    }

    var encodedString: String {
        if let alias = Self.keycodeToAlias[keycode] {
            return alias
        }
        let name = String(cString: SDL_GetKeyName(keycode)).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return String(keycode)
        }
        return KeybindSettingValue.normalizeKeyToken(name)
    }

    var displayString: String {
        encodedString
    }

    private static func normalizeKeyToken(_ string: String) -> String {
        string
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static let aliasToKeycode: [String: SDL_Keycode] = [
        "space": SDLK_SPACE,
        "shift": SDLK_LSHIFT,
        "leftshift": SDLK_LSHIFT,
        "rightshift": SDLK_RSHIFT,
        "escape": SDLK_ESCAPE,
        "esc": SDLK_ESCAPE,
        "return": SDLK_RETURN,
        "enter": SDLK_RETURN,
        "slash": SDLK_SLASH,
        "backslash": SDLK_BACKSLASH,
        "leftbracket": SDLK_LEFTBRACKET,
        "rightbracket": SDLK_RIGHTBRACKET,
        "semicolon": SDLK_SEMICOLON,
        "apostrophe": SDLK_APOSTROPHE,
        "comma": SDLK_COMMA,
        "period": SDLK_PERIOD,
        "minus": SDLK_MINUS,
        "equals": SDLK_EQUALS,
        "backquote": SDLK_GRAVE,
        "grave": SDLK_GRAVE,
        "tab": SDLK_TAB
    ]

    private static let keycodeToAlias: [SDL_Keycode: String] = [
        SDLK_SPACE: "space",
        SDLK_LSHIFT: "leftshift",
        SDLK_RSHIFT: "rightshift",
        SDLK_ESCAPE: "escape",
        SDLK_RETURN: "enter",
        SDLK_SLASH: "/",
        SDLK_BACKSLASH: "\\",
        SDLK_LEFTBRACKET: "[",
        SDLK_RIGHTBRACKET: "]",
        SDLK_SEMICOLON: ";",
        SDLK_APOSTROPHE: "'",
        SDLK_COMMA: ",",
        SDLK_PERIOD: ".",
        SDLK_MINUS: "-",
        SDLK_EQUALS: "=",
        SDLK_GRAVE: "`",
        SDLK_TAB: "tab"
    ]
}

enum KeybindAction: CaseIterable {
    case moveForward
    case moveLeft
    case moveBackward
    case moveRight
    case moveUp
    case moveDown
    case fastMove
    case zoom
    case decreaseRenderDistance
    case increaseRenderDistance
    case addKeyframe
    case openCommandPrompt
    case toggleBiomeMap
    case quitApplication

    var settingName: String {
        switch self {
        case .moveForward:
            return "keybind.moveForward"
        case .moveLeft:
            return "keybind.moveLeft"
        case .moveBackward:
            return "keybind.moveBackward"
        case .moveRight:
            return "keybind.moveRight"
        case .moveUp:
            return "keybind.moveUp"
        case .moveDown:
            return "keybind.moveDown"
        case .fastMove:
            return "keybind.fastMove"
        case .zoom:
            return "keybind.zoom"
        case .decreaseRenderDistance:
            return "keybind.decreaseRenderDistance"
        case .increaseRenderDistance:
            return "keybind.increaseRenderDistance"
        case .addKeyframe:
            return "keybind.addKeyframe"
        case .openCommandPrompt:
            return "keybind.openCommandPrompt"
        case .toggleBiomeMap:
            return "keybind.toggleBiomeMap"
        case .quitApplication:
            return "keybind.quit"
        }
    }

    var summary: String {
        switch self {
        case .moveForward:
            return "Key for moving forward."
        case .moveLeft:
            return "Key for moving left."
        case .moveBackward:
            return "Key for moving backward."
        case .moveRight:
            return "Key for moving right."
        case .moveUp:
            return "Key for moving upward."
        case .moveDown:
            return "Key for moving downward."
        case .fastMove:
            return "Key for fast movement."
        case .zoom:
            return "Key for camera zoom."
        case .decreaseRenderDistance:
            return "Key for decreasing render distance."
        case .increaseRenderDistance:
            return "Key for increasing render distance."
        case .addKeyframe:
            return "Key for adding a cinematic keyframe at the current camera transform."
        case .openCommandPrompt:
            return "Key for opening the command prompt."
        case .toggleBiomeMap:
            return "Key for toggling the biome map."
        case .quitApplication:
            return "Key for quitting the application."
        }
    }

    var defaultValue: KeybindSettingValue {
        switch self {
        case .moveForward:
            return KeybindSettingValue(keycode: SDLK_W)
        case .moveLeft:
            return KeybindSettingValue(keycode: SDLK_A)
        case .moveBackward:
            return KeybindSettingValue(keycode: SDLK_S)
        case .moveRight:
            return KeybindSettingValue(keycode: SDLK_D)
        case .moveUp:
            return KeybindSettingValue(keycode: SDLK_SPACE)
        case .moveDown:
            return KeybindSettingValue(keycode: SDLK_LSHIFT)
        case .fastMove:
            return KeybindSettingValue(keycode: SDLK_R)
        case .zoom:
            return KeybindSettingValue(keycode: SDLK_X)
        case .decreaseRenderDistance:
            return KeybindSettingValue(keycode: SDLK_LEFTBRACKET)
        case .increaseRenderDistance:
            return KeybindSettingValue(keycode: SDLK_RIGHTBRACKET)
        case .addKeyframe:
            return KeybindSettingValue(keycode: SDLK_K)
        case .openCommandPrompt:
            return KeybindSettingValue(keycode: SDLK_SLASH)
        case .toggleBiomeMap:
            return KeybindSettingValue(keycode: SDLK_M)
        case .quitApplication:
            return KeybindSettingValue(keycode: SDLK_ESCAPE)
        }
    }
}
