import Foundation
import SwiftSDL
import VulkanBindings
import Vulkan
import DPReader

@_silgen_name("SDL_Vulkan_GetInstanceExtensions")
private func sdlVulkanGetInstanceExtensions(_ count: UnsafeMutablePointer<UInt32>?) -> UnsafePointer<UnsafePointer<CChar>?>?

@main
final class MineSceneApp {
    private enum CommandHelp {
        static let help = """
        Usage: /help [command]
        Lists all commands, or shows concise help for one command.
        """

        static let tp = """
        Usage: /tp <x> <y> <z>
        Teleports the camera. Coordinates may use relative ~ offsets.
        """

        static let seed = """
        Usage: /seed <subcommand>
        get: print the current seed.
        copy: copy the current seed to the clipboard.
        set <seed>: set the world seed and clear terrain/biome caches.
        paste: read a world seed from the clipboard and apply it.
        """

        static let dimension = """
        Usage: /dimension <subcommand>
        get: print the current noise settings ID.
        list: list discovered noise settings IDs from the loaded datapacks.
        set <id>: rebuild world generation with that noise settings entry.
        This command operates on worldgen noise settings, not the dimension registry itself.
        """

        static let waypoint = """
        Usage: /waypoint <subcommand>
        save <name> [pos] [seed]: save a waypoint.
        load <name>: load a waypoint's seed and position.
        info [name]: list all waypoints, or show one waypoint's details.
        file save|load <file>: use the platform waypoint directory, with .txt implied.
        """

        static let colormap = """
        Usage: /colormap <file>
        Load biome colours from the platform colormap directory, with .txt implied.
        """

        static let setting = """
        Usage: /setting <subcommand>
        get <setting>: print the current value.
        set <setting> <value>: set a value immediately.
        help [setting]: list settings, or show one setting's description and default.
        """

        static let keyframe = """
        Usage: /keyframe <subcommand>
        list: print all keyframes with ID, position, and rotation.
        play: move to the first keyframe, preload all needed chunks, and play the animation.
        remove <id>: remove one keyframe by array index.
        speed [blocks-per-second]: get or set constant playback speed.
        export: render the current keyframe path to an mp4 in the animations directory.
        show|hide: show or hide keyframe markers and the spline path overlay.
        """
    }

    private enum ActiveRenderer {
        case terrain
        case biomeMap
    }

    private struct Waypoint {
        let position: SIMD3<Double>
        let seed: Int64
    }

    private enum CommandError: Error, CustomStringConvertible {
        case unknownSubcommand(command: String, subcommand: String)
        case unknownCommand(String)
        case waypointNotFound(String)
        case clipboardReadFailed
        case clipboardWriteFailed
        case clipboardMissingWorldSeed
        case noiseSettingsNotFound(String)
        case waypointFileReadFailed(String)
        case waypointFileWriteFailed(String)
        case invalidWaypointFile(line: Int, reason: String)
        case colormapFileReadFailed(String)
        case invalidColormapFile(line: Int, reason: String)
        case exportFailed(String)

        var description: String {
            switch self {
            case .unknownSubcommand(let command, let subcommand):
                return "unknown subcommand '\(subcommand)' for /\(command)"
            case .unknownCommand(let command):
                return "unknown command '/\(command)'"
            case .waypointNotFound(let name):
                return "waypoint '\(name)' does not exist"
            case .clipboardReadFailed:
                return "failed to read from the clipboard"
            case .clipboardWriteFailed:
                return "failed to write to the clipboard"
            case .clipboardMissingWorldSeed:
                return "clipboard does not contain a world seed"
            case .noiseSettingsNotFound(let id):
                return "noise settings '\(id)' were not found in the loaded datapacks"
            case .waypointFileReadFailed(let name):
                return "failed to read waypoint file '\(name)'"
            case .waypointFileWriteFailed(let name):
                return "failed to write waypoint file '\(name)'"
            case .invalidWaypointFile(let line, let reason):
                return "invalid waypoint file at line \(line): \(reason)"
            case .colormapFileReadFailed(let name):
                return "failed to read colormap file '\(name)'"
            case .invalidColormapFile(let line, let reason):
                return "invalid colormap file at line \(line): \(reason)"
            case .exportFailed(let reason):
                return "failed to export animation: \(reason)"
            }
        }
    }

    private enum ResourceLookupError: Error, CustomStringConvertible {
        case missing(String)

        var description: String {
            switch self {
            case .missing(let relativePath):
                return "missing required resource '\(relativePath)'"
            }
        }
    }

    private final class SDLRuntime {
        init() throws {
            try SDL_Init(.video)
        }

        deinit {
            SDL_Quit()
        }
    }

    private let sdl: SDLRuntime
    private var window: SDLObject<OpaquePointer>?
    private var instance: VulkanOwnedInstance?
    private var surface: VulkanOwnedSurface?
    private var engine: VulkanEngine?
    private var worldGenerator: WorldGenerator?
    private var terrainRenderer: TerrainRenderer?
    private var biomeMapRenderer: BiomeMapViewRenderer?
    private var imageAvailable: VulkanOwnedSemaphore?
    private var renderFinishedByImage: [VulkanOwnedSemaphore] = []
    private var biomeColorPalette = BiomeColorPalette.defaultPalette()
    private let defaultNoiseSettingsKey = RegistryKey<NoiseSettings>(referencing: "minecraft:overworld")
    private let renderDistanceSetting: Setting<IntSettingValue>
    private let keybindSettings: [KeybindAction: Setting<KeybindSettingValue>]
    private let settingsByName: [String: any SettingProtocol]
    private var dataPacks: [DataPack] = []
    private var currentWorldSeed: Int64 = 0
    private var currentNoiseSettingsKey = RegistryKey<NoiseSettings>(referencing: "minecraft:overworld")
    private var currentBiomeDimensionKey = RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")
    private var waypoints: [String: Waypoint] = [:]
    private var activeRenderer: ActiveRenderer = .terrain

    deinit {
        tearDownRuntime()
    }

    init() throws {
        Self.logStartupStep("initializing settings")
        let settings = Self.makeSettings()
        self.renderDistanceSetting = settings.renderDistance
        self.keybindSettings = settings.keybinds
        self.settingsByName = settings.byName

        Self.logStartupStep("initializing SDL")
        self.sdl = try SDLRuntime()

        Self.logStartupStep("loading datapack paths")
        let datapackPathURLs = try Self.loadOrPromptForDatapackPathURLs()
        Self.logStartupStep("loading \(datapackPathURLs.count) datapack(s)")
        do {
            let loadedDataPacks = try datapackPathURLs.map { try DataPack(fromRootPath: $0) }
            Self.logNoiseSettingsKeys(for: loadedDataPacks, datapackPaths: datapackPathURLs)
            self.dataPacks = loadedDataPacks
        } catch {
            Self.logStartupError("loading datapacks", error: error)
            throw error
        }

        Self.logStartupStep("creating main window")
        let windowPtr = "MineScene".withCString { title in
            SDL_CreateWindow(title, 1200, 840, SDL_WindowFlags.vulkan.rawValue | SDL_WindowFlags.resizable.rawValue)
        }
        guard let windowPtr else {
            throw SDL_Error.error
        }
        self.window = SDLObject<OpaquePointer>(windowPtr, tag: .custom("window"), destroy: { SDL_DestroyWindow($0) })
        if !SDL_SetWindowRelativeMouseMode(windowPtr, true) {
            throw SDL_Error.error
        }

        Self.logStartupStep("querying SDL Vulkan instance extensions")
        var instanceFlags: VulkanInstanceCreateFlags = []
        var instanceExtensions = try MineSceneApp.getSdlVulkanInstanceExtensions()
#if os(macOS)
        instanceFlags.insert(.enumeratePortability)
        instanceExtensions.append(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
#endif
        instanceExtensions = Array(Set(instanceExtensions))

#if DEBUG
        let instanceLayers = ["VK_LAYER_KHRONOS_validation"]
#else
        let instanceLayers: [String] = []
#endif

        Self.logStartupStep("creating Vulkan instance")
        let instance = try VulkanOwnedInstance(
            flags: instanceFlags,
            enabledLayers: instanceLayers,
            enabledExtensions: instanceExtensions,
            appName: "minescene",
            appVersion: 1,
            engineName: nil,
            engineVersion: nil,
            apiVersion: VulkanAPIVersion.v1_3.rawValue
        )
        self.instance = instance

        guard let window else {
            throw SDL_Error.error
        }
        Self.logStartupStep("creating Vulkan surface")
        let surface = try createVulkanSurface(from: window, instance: instance)
        self.surface = surface

        let seed: Int64 = 8608000014473684604
        Self.logStartupStep("loading persisted settings")
        Self.loadSettingsFromDisk(settingsByName: settings.byName)
        self.currentWorldSeed = seed
        self.currentNoiseSettingsKey = defaultNoiseSettingsKey
        self.currentBiomeDimensionKey = biomeDimensionKey(for: defaultNoiseSettingsKey)
        Self.logStartupStep("creating world generator")
        let worldGenerator: WorldGenerator
        do {
            worldGenerator = try makeWorldGenerator(seed: seed, noiseSettingsKey: defaultNoiseSettingsKey)
        } catch {
            Self.logStartupError("creating world generator", error: error)
            throw error
        }
        self.worldGenerator = worldGenerator

        Self.logStartupStep("creating Vulkan engine")
        let engine: VulkanEngine
        do {
            engine = try VulkanEngine(
                instance: instance,
                surface: surface,
                vertSpirvPath: try Self.resourceURL(relativePath: "Shaders/SPIRV/colour2D.vert.spv").path,
                fragSpirvPath: try Self.resourceURL(relativePath: "Shaders/SPIRV/colour2D.frag.spv").path,
                vertSpirv3DPath: try Self.resourceURL(relativePath: "Shaders/SPIRV/colour3D.vert.spv").path,
                fragSpirv3DPath: try Self.resourceURL(relativePath: "Shaders/SPIRV/colour3D.frag.spv").path,
                desiredExtent: .init(width: 1200, height: 840)
            )
        } catch {
            Self.logStartupError("creating Vulkan engine", error: error)
            throw error
        }
        self.engine = engine

        Self.logStartupStep("creating synchronization primitives")
        do {
            self.imageAvailable = try engine.device.createSemaphore()
            self.renderFinishedByImage = try engine.swapchainImages.map { _ in
                try engine.device.createSemaphore()
            }
        } catch {
            Self.logStartupError("creating synchronization primitives", error: error)
            throw error
        }
        Self.logStartupStep("creating terrain renderer")
        self.terrainRenderer = makeTerrainRenderer(worldGenerator: worldGenerator)
        Self.logStartupStep("startup complete")
    }

    static func main() {
        do {
            let app = try MineSceneApp()
            try app.run()
        } catch DatapackSelectionScreen.SelectionError.cancelled {
            return
        } catch {
            logTopLevelError(error)
            exit(1)
        }
    }

    private static func logTopLevelError(_ error: Error) {
        let message = "Error raised at top level: \(error)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private static func logStartupStep(_ message: String) {
        FileHandle.standardError.write(Data("Startup: \(message)\n".utf8))
    }

    private static func logStartupError(_ step: String, error: Error) {
        FileHandle.standardError.write(Data("Startup error during \(step): \(error)\n".utf8))
    }

    private static func logNoiseSettingsKeys(for datapacks: [DataPack], datapackPaths: [URL]) {
        for (index, datapack) in datapacks.enumerated() {
            let path = index < datapackPaths.count ? datapackPaths[index].path : "<unknown>"
            var keys: [String] = []
            datapack.noiseSettingsRegistry.forEach { pair in
                keys.append(pair.key.name)
            }
            keys.sort()

            if keys.isEmpty {
                FileHandle.standardError.write(Data("Startup: datapack \(path) registered no noise settings\n".utf8))
            } else {
                FileHandle.standardError.write(
                    Data("Startup: datapack \(path) noise settings keys: \(keys.joined(separator: ", "))\n".utf8)
                )
            }
        }
    }

    private static func resourceURL(relativePath: String, isDirectory: Bool = false) throws -> URL {
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
            let candidateURL = baseURL.appendingPathComponent(relativePath, isDirectory: isDirectory)
            if fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        if let bundleResourceURL = Bundle.main.resourceURL {
            let candidateURL = bundleResourceURL.appendingPathComponent(relativePath, isDirectory: isDirectory)
            if fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        throw ResourceLookupError.missing(relativePath)
    }

    private func run() throws {
        var running = true
        var event = SDL_Event()
        var previousTickNs = DispatchTime.now().uptimeNanoseconds
        let appWindowID = try window?.id.get()

        discardPendingStartupEvents()

        while running {
            while SDL_PollEvent(&event) {
                switch event.eventType {
                case .quit:
                    running = false
                case .windowCloseRequested, .windowDestroyed:
                    if event.window.windowID == appWindowID {
                        running = false
                    }
                case .keyDown:
                    if !event.key.repeat,
                       keyMatches(event.key.key, action: .toggleBiomeMap),
                       (
                           activeRenderer == .biomeMap ||
                           (terrainRenderer?.isCommandPromptActive != true && terrainRenderer?.isCinematicActive != true)
                       ) {
                        toggleRendererMode()
                        continue
                    }
                    if !event.key.repeat,
                       keyMatches(event.key.key, action: .quitApplication),
                       terrainRenderer?.isCommandPromptActive != true {
                        running = false
                    } else {
                        handleRendererEvent(event)
                    }
                default:
                    handleRendererEvent(event)
                }
            }

            let nowNs = DispatchTime.now().uptimeNanoseconds
            let deltaTime = Float(nowNs - previousTickNs) / 1_000_000_000.0
            previousTickNs = nowNs
            updateRenderer(deltaTime: deltaTime)

            try renderFrame()
            SDL_Delay(16)
        }

        if let engine {
            _ = try? engine.device.waitIdle()
        }

        do {
            try saveSettingsToDisk()
        } catch {
            print("Failed to save settings: \(error)")
        }

        tearDownRuntime()
    }

    private func tearDownRuntime() {
        terrainRenderer = nil
        biomeMapRenderer = nil
        imageAvailable = nil
        renderFinishedByImage.removeAll()
        engine?.shutdown()
        engine = nil
        worldGenerator = nil
        surface = nil
        instance = nil
        window = nil
    }

    private func discardPendingStartupEvents() {
        var event = SDL_Event()
        while SDL_PollEvent(&event) {
            switch event.eventType {
            case .quit, .windowCloseRequested, .windowDestroyed:
                continue
            default:
                continue
            }
        }
    }

    private func renderFrame() throws {
        guard let engine, let imageAvailable, !renderFinishedByImage.isEmpty else {
            return
        }
        switch activeRenderer {
        case .terrain:
            guard let terrainRenderer else { return }
            _ = try terrainRenderer.render(
                engine: engine,
                window: window?.pointer,
                imageAvailable: imageAvailable.semaphore,
                renderFinishedByImage: renderFinishedByImage.map(\.semaphore)
            )
        case .biomeMap:
            guard let biomeMapRenderer else { return }
            try biomeMapRenderer.render(
                engine: engine,
                window: window?.pointer,
                imageAvailable: imageAvailable.semaphore,
                renderFinishedByImage: renderFinishedByImage.map(\.semaphore)
            )
        }
    }

    private func handleRendererEvent(_ event: SDL_Event) {
        switch activeRenderer {
        case .terrain:
            terrainRenderer?.handleEvent(event, window: window?.pointer)
        case .biomeMap:
            biomeMapRenderer?.handleEvent(event, window: window?.pointer)
        }
    }

    private func updateRenderer(deltaTime: Float) {
        switch activeRenderer {
        case .terrain:
            terrainRenderer?.update(deltaTime: deltaTime)
        case .biomeMap:
            biomeMapRenderer?.update(deltaTime: deltaTime)
        }
    }

    private static func makeSettings() -> (
        renderDistance: Setting<IntSettingValue>,
        keybinds: [KeybindAction: Setting<KeybindSettingValue>],
        byName: [String: any SettingProtocol]
    ) {
        let renderDistanceSetting = Setting(
            name: "video.renderDistance",
            summary: "Terrain render distance in chunks.",
            defaultValue: IntSettingValue(value: 12),
            validator: { value in
                value.value >= 0 ? nil : "must be zero or greater"
            }
        )

        var keybindSettings: [KeybindAction: Setting<KeybindSettingValue>] = [:]
        for action in KeybindAction.allCases {
            keybindSettings[action] = Setting(
                name: action.settingName,
                summary: action.summary,
                defaultValue: action.defaultValue
            )
        }

        var settingsByName: [String: any SettingProtocol] = [
            renderDistanceSetting.name: renderDistanceSetting
        ]
        for setting in keybindSettings.values {
            settingsByName[setting.name] = setting
        }

        return (
            renderDistance: renderDistanceSetting,
            keybinds: keybindSettings,
            byName: settingsByName
        )
    }

    private func makeWorldGenerator(
        seed: Int64,
        noiseSettingsKey: RegistryKey<NoiseSettings>
    ) throws -> WorldGenerator {
        try WorldGenerator(
            withWorldSeed: UInt64(bitPattern: seed),
            usingDataPacks: dataPacks,
            usingSettings: noiseSettingsKey
        )
    }

    private func makeTerrainRenderer(worldGenerator: WorldGenerator) -> TerrainRenderer {
        let renderer = TerrainRenderer(
            worldGenerator: worldGenerator,
            biomeColorPalette: biomeColorPalette,
            renderRadius: renderDistanceSetting.value.value
        )
        renderer.externalCommandExecutor = { [weak self] commandName, arguments, terrainRenderer in
            guard let self else {
                return false
            }
            return try self.handleTerrainCommand(
                commandName: commandName,
                arguments: arguments,
                renderer: terrainRenderer
            )
        }
        renderer.keycodeForAction = { [weak self] action in
            self?.keycode(for: action) ?? action.defaultValue.keycode
        }
        renderer.renderDistanceDidChange = { [weak self] renderDistance in
            self?.updateRenderDistanceSetting(renderDistance)
        }
        return renderer
    }

    private func handleTerrainCommand(
        commandName: String,
        arguments: String,
        renderer: TerrainRenderer
    ) throws -> Bool {
        switch commandName {
        case "help":
            var parser = TerrainRendererCommandArgumentParser(arguments)
            if parser.remainingCount == 0 {
                try parser.end()
                logCommandLines([
                    "/help [command]: show command help.",
                    "/tp <pos>: teleport the camera.",
                    "/seed <subcommand>: view or change the world seed.",
                    "/dimension <subcommand>: view or change the active worldgen noise settings.",
                    "/waypoint <subcommand>: manage saved waypoints.",
                    "/keyframe <subcommand>: manage cinematic keyframes.",
                    "/colormap <file>: load a biome colormap file.",
                    "/setting <subcommand>: view or change settings."
                ], renderer: renderer)
            } else {
                let requestedCommand = normalizedCommandName(try parser.getNextString())
                try parser.end()
                logCommandLines(try helpText(for: requestedCommand), renderer: renderer)
            }
            return true
        case "seed":
            var parser = TerrainRendererCommandArgumentParser(arguments)
            let subcommand = try parser.getNextString()
            switch subcommand {
            case "get":
                try parser.end()
                renderer.logCommandMessage("World seed is \(currentWorldSeed).")
            case "copy":
                try parser.end()
                try copyTextToClipboard(String(currentWorldSeed))
                renderer.logCommandMessage("Copied world seed \(currentWorldSeed) to clipboard.")
            case "set":
                let seed = try parser.getNextWorldSeed()
                try parser.end()
                try applyWorldGenerationState(seed: seed, noiseSettingsKey: currentNoiseSettingsKey)
                terrainRenderer?.logCommandMessage("Set world seed to \(seed).")
            case "paste":
                try parser.end()
                let seed = try readWorldSeedFromClipboard()
                try applyWorldGenerationState(seed: seed, noiseSettingsKey: currentNoiseSettingsKey)
                terrainRenderer?.logCommandMessage("Pasted world seed \(seed) from clipboard.")
            default:
                throw CommandError.unknownSubcommand(command: commandName, subcommand: subcommand)
            }
            return true
        case "dimension":
            var parser = TerrainRendererCommandArgumentParser(arguments)
            let subcommand = try parser.getNextString()
            switch subcommand {
            case "get":
                try parser.end()
                renderer.logCommandMessage("Current noise settings ID is \(currentNoiseSettingsKey.name).")
            case "list":
                try parser.end()
                let discoveredIDs = discoveredNoiseSettingsIDs()
                if discoveredIDs.isEmpty {
                    renderer.logCommandMessage("No noise settings IDs were discovered in the loaded datapacks.")
                } else {
                    renderer.logCommandMessage(
                        "Discovered noise settings IDs (\(discoveredIDs.count)): \(discoveredIDs.joined(separator: ", "))"
                    )
                }
            case "set":
                let requestedID = try parser.getNextString()
                try parser.end()
                let noiseSettingsKey = try noiseSettingsKey(for: requestedID)
                try applyWorldGenerationState(seed: currentWorldSeed, noiseSettingsKey: noiseSettingsKey)
                terrainRenderer?.logCommandMessage("Set worldgen noise settings to \(noiseSettingsKey.name).")
            default:
                throw CommandError.unknownSubcommand(command: commandName, subcommand: subcommand)
            }
            return true
        case "waypoint":
            var parser = TerrainRendererCommandArgumentParser(arguments)
            let subcommand = try parser.getNextString()
            switch subcommand {
            case "save":
                let name = try parser.getNextString()
                let currentPosition = renderer.cameraPosition
                let position: SIMD3<Double>
                let seed: Int64
                switch parser.remainingCount {
                case 0:
                    position = currentPosition
                    seed = currentWorldSeed
                case 1:
                    position = currentPosition
                    seed = try parser.getNextWorldSeed()
                case 3:
                    position = try parser.getNextPos(currentPosition: currentPosition)
                    seed = currentWorldSeed
                case 4:
                    position = try parser.getNextPos(currentPosition: currentPosition)
                    seed = try parser.getNextWorldSeed()
                default:
                    throw TerrainRendererCommandParseError.invalidArguments(
                        "expected /waypoint save <name> [pos] [seed]"
                    )
                }
                try parser.end()
                waypoints[name] = Waypoint(position: position, seed: seed)
                renderer.logCommandMessage(
                    "Saved waypoint \(name) at \(formatPosition(position, renderer: renderer)) on world seed \(seed)."
                )
            case "info":
                if parser.remainingCount == 0 {
                    try parser.end()
                    if waypoints.isEmpty {
                        renderer.logCommandMessage("No waypoints saved.")
                    } else {
                        for (name, waypoint) in sortedWaypoints() {
                            renderer.logCommandMessage(
                                "\(name): \(formatPosition(waypoint.position, renderer: renderer)) on world seed \(waypoint.seed)."
                            )
                        }
                    }
                } else {
                    let name = try parser.getNextString()
                    try parser.end()
                    guard let waypoint = waypoints[name] else {
                        throw CommandError.waypointNotFound(name)
                    }
                    renderer.logCommandMessage(
                        "Waypoint \(name): \(formatPosition(waypoint.position, renderer: renderer)) on world seed \(waypoint.seed)."
                    )
                }
            case "load":
                let name = try parser.getNextString()
                try parser.end()
                guard let waypoint = waypoints[name] else {
                    throw CommandError.waypointNotFound(name)
                }
                try applyWorldGenerationState(seed: waypoint.seed, noiseSettingsKey: currentNoiseSettingsKey)
                terrainRenderer?.cameraPosition = waypoint.position
                if let terrainRenderer {
                    terrainRenderer.logCommandMessage(
                        "Loaded waypoint \(name) at \(formatPosition(waypoint.position, renderer: terrainRenderer)) on world seed \(waypoint.seed)."
                    )
                }
            case "file":
                let fileSubcommand = try parser.getNextString()
                switch fileSubcommand {
                case "save":
                    let filepath = try parser.getNextLocalFilepath()
                    try parser.end()
                    let fileURL = try waypointFileURL(for: filepath)
                    try saveWaypoints(to: fileURL, displayName: waypointFileDisplayName(for: filepath))
                    renderer.logCommandMessage(
                        "Saved \(waypoints.count) waypoint(s) to \(waypointFileDisplayName(for: filepath))."
                    )
                case "load":
                    let filepath = try parser.getNextLocalFilepath()
                    try parser.end()
                    let fileURL = try waypointFileURL(for: filepath)
                    let loadedWaypointCount = try loadWaypoints(from: fileURL, displayName: waypointFileDisplayName(for: filepath))
                    renderer.logCommandMessage(
                        "Loaded \(loadedWaypointCount) waypoint(s) from \(waypointFileDisplayName(for: filepath))."
                    )
                default:
                    throw CommandError.unknownSubcommand(command: "waypoint file", subcommand: fileSubcommand)
                }
            default:
                throw CommandError.unknownSubcommand(command: commandName, subcommand: subcommand)
            }
            return true
        case "keyframe":
            var parser = TerrainRendererCommandArgumentParser(arguments)
            let subcommand = try parser.getNextString()
            switch subcommand {
            case "list":
                try parser.end()
                if renderer.keyframes.isEmpty {
                    renderer.logCommandMessage("No keyframes saved.")
                } else {
                    for (id, keyframe) in renderer.keyframes.enumerated() {
                        renderer.logCommandMessage(renderer.formatKeyframeDescription(id: id, keyframe: keyframe))
                    }
                }
            case "play":
                try parser.end()
                try renderer.startKeyframePlayback()
            case "remove":
                let id = try parser.getNextInt()
                try parser.end()
                let removedKeyframe = try renderer.removeKeyframe(id: id)
                renderer.logCommandMessage(
                    "Removed keyframe \(id) at \(renderer.formatCommandPosition(removedKeyframe.position))."
                )
            case "show":
                try parser.end()
                renderer.showsKeyframes = true
                renderer.logCommandMessage("Showing keyframes and cinematic path.")
            case "hide":
                try parser.end()
                renderer.showsKeyframes = false
                renderer.logCommandMessage("Hiding keyframes and cinematic path.")
            case "speed":
                if parser.remainingCount == 0 {
                    try parser.end()
                    renderer.logCommandMessage("Keyframe speed is \(renderer.formatPlaybackSpeed(renderer.keyframePlaybackSpeed)).")
                } else {
                    let speed = try parser.getNextDouble()
                    try parser.end()
                    guard speed > 0 else {
                        throw TerrainRendererCommandParseError.invalidArguments("speed must be greater than zero")
                    }
                    renderer.setKeyframePlaybackSpeed(speed)
                    renderer.logCommandMessage("Set keyframe speed to \(renderer.formatPlaybackSpeed(renderer.keyframePlaybackSpeed)).")
                }
            case "export":
                try parser.end()
                let outputURL = try exportCurrentKeyframeAnimation(renderer: renderer)
                renderer.logCommandMessage("Exported animation to \(outputURL.path).")
            default:
                throw CommandError.unknownSubcommand(command: commandName, subcommand: subcommand)
            }
            return true
        case "colormap":
            var parser = TerrainRendererCommandArgumentParser(arguments)
            let filepath = try parser.getNextLocalFilepath()
            try parser.end()
            let displayName = colormapFileDisplayName(for: filepath)
            let palette = try loadColormap(
                from: try colormapFileURL(for: filepath),
                displayName: displayName
            )
            applyBiomeColorPalette(palette)
            terrainRenderer?.logCommandMessage("Loaded colormap from \(displayName).")
            return true
        case "setting":
            var parser = TerrainRendererCommandArgumentParser(arguments)
            let subcommand = try parser.getNextString()
            switch subcommand {
            case "set":
                let settingName = try parser.getNextString()
                let value = try parser.getNextString()
                try parser.end()
                let setting = try setting(named: settingName)
                try setting.setValue(from: value)
                applyRuntimeSettingIfNeeded(named: settingName)
                renderer.logCommandMessage("Set setting \(settingName) to \(setting.currentValueDescription).")
            case "get":
                let settingName = try parser.getNextString()
                try parser.end()
                let setting = try setting(named: settingName)
                renderer.logCommandMessage("\(settingName) = \(setting.currentValueDescription)")
            case "help":
                if parser.remainingCount == 0 {
                    try parser.end()
                    let names = settingsByName.keys.sorted().joined(separator: ", ")
                    renderer.logCommandMessage("Available settings: \(names)")
                } else {
                    let settingName = try parser.getNextString()
                    try parser.end()
                    let setting = try setting(named: settingName)
                    renderer.logCommandMessage(
                        "\(setting.name): \(setting.summary) Default: \(setting.defaultValueDescription)."
                    )
                }
            default:
                throw CommandError.unknownSubcommand(command: commandName, subcommand: subcommand)
            }
            return true
        default:
            return false
        }
    }

    private func applyWorldGenerationState(
        seed: Int64,
        noiseSettingsKey: RegistryKey<NoiseSettings>
    ) throws {
        let newWorldGenerator = try makeWorldGenerator(seed: seed, noiseSettingsKey: noiseSettingsKey)
        waitForGpuToFinishCurrentFrame()

        terrainRenderer?.discardChunkMeshes()
        biomeMapRenderer?.discardData()

        worldGenerator = newWorldGenerator
        currentWorldSeed = seed
        currentNoiseSettingsKey = noiseSettingsKey
        currentBiomeDimensionKey = biomeDimensionKey(for: noiseSettingsKey)
        replaceTerrainRenderer(worldGenerator: newWorldGenerator, preserveKeyframes: false)

        if activeRenderer == .biomeMap, let terrainRenderer {
            let biomeMapRenderer = BiomeMapViewRenderer(
                worldGenerator: newWorldGenerator,
                biomeColorPalette: biomeColorPalette
            )
            biomeMapRenderer.dimensionKey = currentBiomeDimensionKey
            biomeMapRenderer.recenter(on: terrainRenderer.currentCameraPosition)
            self.biomeMapRenderer = biomeMapRenderer
        }
    }

    private func copyTextToClipboard(_ text: String) throws {
        let didSet = text.withCString { SDL_SetClipboardText($0) }
        guard didSet else {
            throw CommandError.clipboardWriteFailed
        }
    }

    private func readWorldSeedFromClipboard() throws -> Int64 {
        guard let clipboardTextPointer = SDL_GetClipboardText() else {
            throw CommandError.clipboardReadFailed
        }
        defer { SDL_free(clipboardTextPointer) }
        let clipboardText = String(cString: clipboardTextPointer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clipboardText.isEmpty else {
            throw CommandError.clipboardMissingWorldSeed
        }
        var parser = TerrainRendererCommandArgumentParser(clipboardText)
        let seed = try parser.getNextWorldSeed()
        try parser.end()
        return seed
    }

    private func formatPosition(_ position: SIMD3<Double>, renderer: TerrainRenderer) -> String {
        "(\(renderer.formatCommandNumber(position.x)), \(renderer.formatCommandNumber(position.y)), \(renderer.formatCommandNumber(position.z)))"
    }

    private func formatWaypointFilePosition(_ position: SIMD3<Double>, renderer: TerrainRenderer?) -> String {
        let formatter = renderer ?? terrainRenderer
        let x = formatter?.formatCommandNumber(position.x) ?? String(position.x)
        let y = formatter?.formatCommandNumber(position.y) ?? String(position.y)
        let z = formatter?.formatCommandNumber(position.z) ?? String(position.z)
        return "\(x) \(y) \(z)"
    }

    private func normalizedCommandName(_ command: String) -> String {
        if command.first == "/" {
            return String(command.dropFirst())
        }
        return command
    }

    private func helpText(for command: String) throws -> [String] {
        switch command {
        case "help":
            return CommandHelp.help.split(separator: "\n").map(String.init)
        case "tp":
            return CommandHelp.tp.split(separator: "\n").map(String.init)
        case "seed":
            return CommandHelp.seed.split(separator: "\n").map(String.init)
        case "dimension":
            return CommandHelp.dimension.split(separator: "\n").map(String.init)
        case "waypoint":
            return CommandHelp.waypoint.split(separator: "\n").map(String.init)
        case "keyframe":
            return CommandHelp.keyframe.split(separator: "\n").map(String.init)
        case "colormap":
            return CommandHelp.colormap.split(separator: "\n").map(String.init)
        case "setting":
            return CommandHelp.setting.split(separator: "\n").map(String.init)
        default:
            throw CommandError.unknownCommand(command)
        }
    }

    private func logCommandLines(_ lines: [String], renderer: TerrainRenderer) {
        for line in lines where !line.isEmpty {
            renderer.logCommandMessage(line)
        }
    }

    private func keycode(for action: KeybindAction) -> SDL_Keycode {
        keybindSettings[action]?.value.keycode ?? action.defaultValue.keycode
    }

    private func keyMatches(_ key: SDL_Keycode, action: KeybindAction) -> Bool {
        key == keycode(for: action)
    }

    private func setting(named name: String) throws -> any SettingProtocol {
        guard let setting = settingsByName[name] else {
            throw SettingError.unknownSetting(name)
        }
        return setting
    }

    private func applyRuntimeSettingIfNeeded(named name: String) {
        if name == renderDistanceSetting.name {
            terrainRenderer?.setRenderRadius(renderDistanceSetting.value.value)
        }
    }

    private func updateRenderDistanceSetting(_ renderDistance: Int) {
        try? renderDistanceSetting.setValue(from: String(renderDistance))
    }

    private func exportCurrentKeyframeAnimation(renderer: TerrainRenderer) throws -> URL {
        guard let engine, let imageAvailable, !renderFinishedByImage.isEmpty else {
            throw CommandError.exportFailed("renderer is not ready")
        }

        let preparation = try renderer.currentCinematicPreparationPlan()
        let originalPosition = renderer.cameraPosition
        let originalYaw = renderer.cameraYaw
        let originalPitch = renderer.cameraPitch
        let originalExportState = renderer.isRenderingForExport
        let originalPlaybackSession = renderer.cinematicPlaybackSession

        renderer.resetMovementKeys()
        renderer.cameraPosition = preparation.initialKeyframe.position
        renderer.cameraYaw = preparation.initialKeyframe.yaw
        renderer.cameraPitch = preparation.initialKeyframe.pitch
        renderer.cinematicPlaybackSession = nil
        renderer.isRenderingForExport = false
        renderer.streamer.setPinnedChunks(preparation.pinnedChunks)

        defer {
            renderer.streamer.setPinnedChunks(originalPlaybackSession?.pinnedChunks ?? [])
            renderer.cameraPosition = originalPosition
            renderer.cameraYaw = originalYaw
            renderer.cameraPitch = originalPitch
            renderer.isRenderingForExport = originalExportState
            renderer.cinematicPlaybackSession = originalPlaybackSession
        }

        renderer.logCommandMessage(
            "Preparing animation export across \(preparation.pinnedChunks.count) chunks at \(renderer.formatPlaybackSpeed(renderer.keyframePlaybackSpeed))."
        )
        try waitForCinematicPreparation(renderer: renderer)
        renderer.logCommandMessage("Starting animation export.")

        let outputURL = try animationFileURLForCurrentTime()
        let frameRate = 60
        let duration = max(preparation.path.totalDuration, 0)
        let frameCount = max(1, Int(ceil(duration * Double(frameRate))) + 1)

        waitForGpuToFinishCurrentFrame()
        renderer.isRenderingForExport = true
        let firstCapturedFrame = try renderer.render(
            engine: engine,
            window: window?.pointer,
            imageAvailable: imageAvailable.semaphore,
            renderFinishedByImage: renderFinishedByImage.map(\.semaphore)
        )
        guard let firstCapturedFrame else {
            throw CommandError.exportFailed("failed to capture the first frame")
        }

        let writer = try AnimationVideoWriter(
            outputURL: outputURL,
            width: firstCapturedFrame.width,
            height: firstCapturedFrame.height,
            framesPerSecond: frameRate
        )
        try writer.appendFrame(firstCapturedFrame, frameIndex: 0)

        if frameCount > 1 {
            for frameIndex in 1..<frameCount {
                let time = min(Double(frameIndex) / Double(frameRate), duration)
                let sample = renderer.samplePlaybackPath(preparation.path, at: time)
                renderer.cameraPosition = sample.position
                renderer.cameraYaw = sample.yaw
                renderer.cameraPitch = sample.pitch

                guard let capturedFrame = try renderer.render(
                    engine: engine,
                    window: window?.pointer,
                    imageAvailable: imageAvailable.semaphore,
                    renderFinishedByImage: renderFinishedByImage.map(\.semaphore)
                ) else {
                    throw CommandError.exportFailed("failed to capture frame \(frameIndex)")
                }
                try writer.appendFrame(capturedFrame, frameIndex: frameIndex)

                if frameIndex % frameRate == 0 || frameIndex == frameCount - 1 {
                    renderer.logCommandMessage("Export progress: \(frameIndex + 1)/\(frameCount) frames.")
                }
            }
        }

        try writer.finish()
        renderer.isRenderingForExport = false
        waitForGpuToFinishCurrentFrame()
        return outputURL
    }

    private func waitForCinematicPreparation(renderer: TerrainRenderer) throws {
        var lastReportedReadyCount = -1
        while true {
            let status = renderer.streamer.pinnedChunkPreparationStatus()
            if status.readyChunks == status.totalChunks {
                return
            }
            if status.readyChunks != lastReportedReadyCount {
                renderer.logCommandMessage(
                    "Export prep: \(status.readyChunks)/\(status.totalChunks) ready, gen \(status.generatingChunks), mesh \(status.meshingChunks)."
                )
                lastReportedReadyCount = status.readyChunks
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func sortedWaypoints() -> [(name: String, waypoint: Waypoint)] {
        waypoints
            .map { (name: $0.key, waypoint: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private static func appDataDirectoryURL() -> URL {
#if os(Linux)
        let baseDirectory: URL
        if let xdgDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"],
           !xdgDataHome.isEmpty {
            baseDirectory = URL(fileURLWithPath: xdgDataHome, isDirectory: true)
        } else {
            baseDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        return baseDirectory
            .appendingPathComponent("minescene", isDirectory: true)
#else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("minescene", isDirectory: true)
#endif
    }

    private static func appDataDirectoryDisplayName() -> String {
#if os(Linux)
        if let xdgDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"],
           !xdgDataHome.isEmpty {
            return "\(xdgDataHome)/minescene"
        }
        return "~/.local/share/minescene"
#else
        return "~/Documents/minescene"
#endif
    }

    private static func settingsFileURL() -> URL {
        appDataDirectoryURL().appendingPathComponent("settings.json", isDirectory: false)
    }

    private static func datapackPathsFileURL() -> URL {
        appDataDirectoryURL().appendingPathComponent("datapack_paths.txt", isDirectory: false)
    }

    private static func loadOrPromptForDatapackPathURLs() throws -> [URL] {
        let fileURL = datapackPathsFileURL()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try loadDatapackPathURLs(from: fileURL)
        }

        let selectedURLs = try promptForDatapackPathURLs()
        try saveDatapackPathURLs(selectedURLs, to: fileURL)
        return selectedURLs
    }

    @inline(never)
    private static func promptForDatapackPathURLs() throws -> [URL] {
        let selectionScreen = try DatapackSelectionScreen()
        return try selectionScreen.run()
    }

    private static func loadDatapackPathURLs(from fileURL: URL) throws -> [URL] {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        return contents
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map {
                URL(
                    fileURLWithPath: NSString(string: $0).expandingTildeInPath,
                    isDirectory: true
                ).standardizedFileURL
            }
    }

    private static func saveDatapackPathURLs(_ urls: [URL], to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let contents = urls
            .map { $0.standardizedFileURL.path }
            .joined(separator: "\n")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func loadSettingsFromDisk(settingsByName: [String: any SettingProtocol]) {
        let fileURL = settingsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let storedSettings = try JSONDecoder().decode([String: String].self, from: data)
            for (name, value) in storedSettings {
                guard let setting = settingsByName[name] else {
                    continue
                }
                do {
                    try setting.loadPersistedValue(from: value)
                } catch {
                    print("Failed to load setting \(name): \(error)")
                }
            }
        } catch {
            print("Failed to load settings from \(fileURL.path): \(error)")
        }
    }

    private func saveSettingsToDisk() throws {
        let directoryURL = Self.appDataDirectoryURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let storedSettings = Dictionary(uniqueKeysWithValues: settingsByName.map { name, setting in
            (name, setting.persistedValueString())
        })
        let data = try JSONEncoder().encode(storedSettings)
        try data.write(to: Self.settingsFileURL(), options: .atomic)
    }

    private func waypointFilesDirectoryURL() -> URL {
        Self.appDataDirectoryURL().appendingPathComponent("waypoints", isDirectory: true)
    }

    private func colormapFilesDirectoryURL() -> URL {
        Self.appDataDirectoryURL().appendingPathComponent("colormaps", isDirectory: true)
    }

    private func animationFilesDirectoryURL() -> URL {
        Self.appDataDirectoryURL().appendingPathComponent("animations", isDirectory: true)
    }

    private func waypointFileURL(for localPath: String) throws -> URL {
        let normalizedPath: String
        if localPath.hasSuffix(".txt") {
            normalizedPath = localPath
        } else {
            normalizedPath = "\(localPath).txt"
        }
        return waypointFilesDirectoryURL().appendingPathComponent(normalizedPath, isDirectory: false)
    }

    private func waypointFileDisplayName(for localPath: String) -> String {
        let normalizedPath: String
        if localPath.hasSuffix(".txt") {
            normalizedPath = localPath
        } else {
            normalizedPath = "\(localPath).txt"
        }
        return "\(Self.appDataDirectoryDisplayName())/waypoints/\(normalizedPath)"
    }

    private func colormapFileURL(for localPath: String) throws -> URL {
        let normalizedPath: String
        if localPath.hasSuffix(".txt") {
            normalizedPath = localPath
        } else {
            normalizedPath = "\(localPath).txt"
        }
        return colormapFilesDirectoryURL().appendingPathComponent(normalizedPath, isDirectory: false)
    }

    private func colormapFileDisplayName(for localPath: String) -> String {
        let normalizedPath: String
        if localPath.hasSuffix(".txt") {
            normalizedPath = localPath
        } else {
            normalizedPath = "\(localPath).txt"
        }
        return "\(Self.appDataDirectoryDisplayName())/colormaps/\(normalizedPath)"
    }

    private func animationFileURLForCurrentTime() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd.HH:mm:ss.SSS"
        let fileName = "\(formatter.string(from: Date())).mp4"
        let directoryURL = animationFilesDirectoryURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private func saveWaypoints(to fileURL: URL, displayName: String) throws {
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let contents = sortedWaypoints().map { name, waypoint in
                "\(name) \(waypoint.seed) \(formatWaypointFilePosition(waypoint.position, renderer: terrainRenderer))"
            }.joined(separator: "\n")
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw CommandError.waypointFileWriteFailed(displayName)
        }
    }

    private func loadWaypoints(from fileURL: URL, displayName: String) throws -> Int {
        let contents: String
        do {
            contents = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw CommandError.waypointFileReadFailed(displayName)
        }

        var loadedWaypointCount = 0
        let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (lineIndex, rawLine) in lines.enumerated() {
            let lineNumber = lineIndex + 1
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }

            var parser = TerrainRendererCommandArgumentParser(line)
            let name: String
            let seed: Int64
            let position: SIMD3<Double>
            do {
                name = try parser.getNextString()
                seed = try parser.getNextWorldSeed()
                let x = try parser.getNextDouble()
                let y = try parser.getNextDouble()
                let z = try parser.getNextDouble()
                try parser.end()
                position = SIMD3<Double>(x, y, z)
            } catch let error as TerrainRendererCommandParseError {
                throw CommandError.invalidWaypointFile(line: lineNumber, reason: error.description)
            }

            waypoints[name] = Waypoint(position: position, seed: seed)
            loadedWaypointCount += 1
        }

        return loadedWaypointCount
    }

    private func loadColormap(from fileURL: URL, displayName: String) throws -> BiomeColorPalette {
        let contents: String
        do {
            contents = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw CommandError.colormapFileReadFailed(displayName)
        }

        var overrides: [String: (UInt8, UInt8, UInt8, UInt8)] = [:]
        let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (lineIndex, rawLine) in lines.enumerated() {
            let lineNumber = lineIndex + 1
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }

            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count == 4 else {
                throw CommandError.invalidColormapFile(
                    line: lineNumber,
                    reason: "expected '<biome-id> <red> <green> <blue>'"
                )
            }

            let biomeID = BiomeColorPalette.normalizedBiomeID(parts[0])
            guard !biomeID.isEmpty else {
                throw CommandError.invalidColormapFile(
                    line: lineNumber,
                    reason: "expected a biome identifier"
                )
            }

            let red = try parseColormapComponent(parts[1], line: lineNumber, name: "red")
            let green = try parseColormapComponent(parts[2], line: lineNumber, name: "green")
            let blue = try parseColormapComponent(parts[3], line: lineNumber, name: "blue")
            overrides[biomeID] = (red, green, blue, 255)
        }

        return BiomeColorPalette.defaultPalette().overridingColorsRGBA8(overrides)
    }

    private func parseColormapComponent(
        _ token: String,
        line: Int,
        name: String
    ) throws -> UInt8 {
        guard !token.isEmpty, token.allSatisfy(Self.isASCIIDigit), let value = Int(token), (0...255).contains(value) else {
            throw CommandError.invalidColormapFile(
                line: line,
                reason: "\(name) component '\(token)' is not a decimal number from 0 to 255"
            )
        }
        return UInt8(value)
    }

    private func applyBiomeColorPalette(_ palette: BiomeColorPalette) {
        guard let worldGenerator else {
            biomeColorPalette = palette
            return
        }

        waitForGpuToFinishCurrentFrame()
        terrainRenderer?.discardChunkMeshes()
        biomeMapRenderer?.discardData()
        biomeColorPalette = palette
        replaceTerrainRenderer(worldGenerator: worldGenerator, preserveKeyframes: true)

        if activeRenderer == .biomeMap, let terrainRenderer {
            let biomeMapRenderer = BiomeMapViewRenderer(
                worldGenerator: worldGenerator,
                biomeColorPalette: biomeColorPalette
            )
            biomeMapRenderer.dimensionKey = currentBiomeDimensionKey
            biomeMapRenderer.recenter(on: terrainRenderer.currentCameraPosition)
            self.biomeMapRenderer = biomeMapRenderer
        }
    }

    private func replaceTerrainRenderer(worldGenerator: WorldGenerator, preserveKeyframes: Bool) {
        let previousCameraPosition = terrainRenderer?.cameraPosition ?? SIMD3<Double>(x: 0, y: 160, z: 0)
        let previousCameraYaw = terrainRenderer?.cameraYaw ?? -.pi / 4.0
        let previousCameraPitch = terrainRenderer?.cameraPitch ?? -.pi / 5.5
        let previousSmoothedFps = terrainRenderer?.smoothedFps ?? 0
        let previousCommandLogEntries = terrainRenderer?.commandLogEntries ?? []
        let previousCommandPromptHistory = terrainRenderer?.commandPromptHistory ?? []
        let previousKeyframes = preserveKeyframes ? (terrainRenderer?.keyframes ?? []) : []
        let previousShowsKeyframes = preserveKeyframes ? (terrainRenderer?.showsKeyframes ?? false) : false
        let previousKeyframePlaybackSpeed = terrainRenderer?.keyframePlaybackSpeed ?? 8.0

        let newTerrainRenderer = makeTerrainRenderer(worldGenerator: worldGenerator)
        newTerrainRenderer.cameraPosition = previousCameraPosition
        newTerrainRenderer.cameraYaw = previousCameraYaw
        newTerrainRenderer.cameraPitch = previousCameraPitch
        newTerrainRenderer.smoothedFps = previousSmoothedFps
        newTerrainRenderer.commandLogEntries = previousCommandLogEntries
        newTerrainRenderer.commandPromptHistory = previousCommandPromptHistory
        newTerrainRenderer.keyframePlaybackSpeed = previousKeyframePlaybackSpeed
        newTerrainRenderer.keyframes = previousKeyframes
        newTerrainRenderer.showsKeyframes = previousShowsKeyframes
        terrainRenderer = newTerrainRenderer
    }

    private func toggleRendererMode() {
        switch activeRenderer {
        case .terrain:
            guard let terrainRenderer, let worldGenerator else {
                return
            }
            waitForGpuToFinishCurrentFrame()
            terrainRenderer.discardChunkMeshes()
            let biomeMapRenderer = BiomeMapViewRenderer(
                worldGenerator: worldGenerator,
                biomeColorPalette: biomeColorPalette
            )
            biomeMapRenderer.dimensionKey = currentBiomeDimensionKey
            biomeMapRenderer.recenter(on: terrainRenderer.currentCameraPosition)
            self.biomeMapRenderer = biomeMapRenderer
            setRelativeMouseMode(enabled: false)
            activeRenderer = .biomeMap
        case .biomeMap:
            waitForGpuToFinishCurrentFrame()
            biomeMapRenderer?.discardData()
            biomeMapRenderer = nil
            terrainRenderer?.requestChunkMeshRebuild()
            setRelativeMouseMode(enabled: true)
            activeRenderer = .terrain
        }
    }

    private func waitForGpuToFinishCurrentFrame() {
        guard let engine else {
            return
        }
        _ = try? engine.device.waitForFences([engine.inFlightFence.fence], waitAll: true, timeout: UInt64.max)
    }

    private func setRelativeMouseMode(enabled: Bool) {
        guard let window = window?.pointer else {
            return
        }
        _ = SDL_SetWindowRelativeMouseMode(window, enabled)
    }

    private static func getSdlVulkanInstanceExtensions() throws -> [String] {
        var count: UInt32 = 0
        guard let extensionsPtr = sdlVulkanGetInstanceExtensions(&count) else {
            throw SDL_Error.error
        }
        let buffer = UnsafeBufferPointer(start: extensionsPtr, count: Int(count))
        return buffer.compactMap { $0 }.map { String(cString: $0) }
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }
    
    private func discoveredNoiseSettingsIDs() -> [String] {
        var discoveredIDs: Set<String> = []
        for dataPack in dataPacks {
            dataPack.noiseSettingsRegistry.forEach { entry in
                discoveredIDs.insert(entry.key.name)
            }
        }
        return discoveredIDs.sorted()
    }

    private func noiseSettingsKey(for requestedID: String) throws -> RegistryKey<NoiseSettings> {
        let normalizedID = normalizeRegistryID(requestedID)
        guard discoveredNoiseSettingsIDs().contains(normalizedID) else {
            throw CommandError.noiseSettingsNotFound(normalizedID)
        }
        return RegistryKey<NoiseSettings>(referencing: normalizedID)
    }

    private func biomeDimensionKey(for noiseSettingsKey: RegistryKey<NoiseSettings>) -> RegistryKey<DPReader.Dimension> {
        switch noiseSettingsKey.name {
        case "minecraft:nether":
            return RegistryKey<DPReader.Dimension>(referencing: "minecraft:nether")
        case "minecraft:end":
            return RegistryKey<DPReader.Dimension>(referencing: "minecraft:the_end")
        default:
            return noiseSettingsKey.convertType()
        }
    }

    private func normalizeRegistryID(_ identifier: String) -> String {
        identifier.contains(":") ? identifier : "minecraft:\(identifier)"
    }
}
