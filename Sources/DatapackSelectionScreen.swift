import Foundation
import SwiftSDL

private func datapackFolderDialogCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ fileList: UnsafePointer<UnsafePointer<CChar>?>?,
    _ filter: Int32
) {
    _ = filter
    guard let userdata else {
        return
    }

    let resultBox = Unmanaged<DatapackSelectionScreen.DialogResultBox>.fromOpaque(userdata).takeUnretainedValue()

    guard let fileList else {
        let message = String(cString: SDL_GetError())
        resultBox.store(.failure(message.isEmpty ? "Folder picker failed." : message))
        return
    }

    var selectedPaths: [String] = []
    var cursor = fileList
    while let pathPointer = cursor.pointee {
        selectedPaths.append(String(cString: pathPointer))
        cursor = cursor.advanced(by: 1)
    }

    if selectedPaths.isEmpty {
        resultBox.store(.cancelled)
    } else {
        resultBox.store(.selected(selectedPaths))
    }
}

final class DatapackSelectionScreen {
    enum SelectionError: Error, CustomStringConvertible {
        case cancelled

        var description: String {
            switch self {
            case .cancelled:
                return "datapack selection was cancelled"
            }
        }
    }

    enum DialogResult {
        case selected([String])
        case cancelled
        case failure(String)
    }

    final class DialogResultBox {
        private let lock = NSLock()
        private var pendingResult: DialogResult?

        func store(_ result: DialogResult) {
            lock.lock()
            pendingResult = result
            lock.unlock()
        }

        func take() -> DialogResult? {
            lock.lock()
            defer { lock.unlock() }
            let result = pendingResult
            pendingResult = nil
            return result
        }
    }

    private enum Action {
        case addFolders
        case removeSelected
        case moveSelectedUp
        case moveSelectedDown
        case saveAndContinue
        case quit
    }

    private struct Button {
        let title: String
        let action: Action
        let rect: SDL_FRect
    }

    private static let backgroundColor = SDL_Color(r: 16, g: 18, b: 24, a: 255)
    private static let panelColor = SDL_Color(r: 28, g: 34, b: 44, a: 255)
    private static let panelBorderColor = SDL_Color(r: 74, g: 90, b: 112, a: 255)
    private static let rowColor = SDL_Color(r: 36, g: 42, b: 54, a: 255)
    private static let selectedRowColor = SDL_Color(r: 82, g: 115, b: 168, a: 255)
    private static let buttonColor = SDL_Color(r: 52, g: 61, b: 78, a: 255)
    private static let buttonActiveColor = SDL_Color(r: 100, g: 129, b: 180, a: 255)
    private static let textColor = SDL_Color(r: 240, g: 244, b: 250, a: 255)
    private static let mutedTextColor = SDL_Color(r: 182, g: 191, b: 206, a: 255)
    private static let successTextColor = SDL_Color(r: 166, g: 224, b: 167, a: 255)
    private static let errorTextColor = SDL_Color(r: 247, g: 155, b: 155, a: 255)

    private var window: SDLObject<OpaquePointer>?
    private var renderer: SDLObject<OpaquePointer>?
    private let dialogResultBox = DialogResultBox()

    private var datapackPaths: [String] = []
    private var selectedIndex: Int?
    private var listScrollOffset = 0
    private var isFolderDialogOpen = false
    private var statusMessage = "Select one or more datapack folders. The top entry is applied first."
    private var statusColor = DatapackSelectionScreen.mutedTextColor

    init() throws {
        let windowPtr = "MineScene Datapacks".withCString { title in
            SDL_CreateWindow(title, 1120, 760, SDL_WindowFlags.resizable.rawValue)
        }
        guard let windowPtr else {
            throw SDL_Error.error
        }
        self.window = SDLObject<OpaquePointer>(windowPtr, tag: .custom("datapack picker window"), destroy: { SDL_DestroyWindow($0) })

        guard let rendererPtr = SDL_CreateRenderer(windowPtr, nil) else {
            throw SDL_Error.error
        }
        self.renderer = SDLObject<OpaquePointer>(rendererPtr, tag: .custom("datapack picker renderer"), destroy: { SDL_DestroyRenderer($0) })

        if let renderer {
            _ = try? renderer.set(vsync: 1)
        }
        if let window {
            _ = try? window.set(minSize: SDL_Size([900, 640]))
        }
    }

    func run() throws -> [URL] {
        defer { shutdown() }
        var event = SDL_Event()

        while true {
            while SDL_PollEvent(&event) {
                if try handle(event: event) {
                    return try finalizedSelection()
                }
            }

            if processDialogResultIfNeeded() {
                return try finalizedSelection()
            }

            try render()
            SDL_Delay(16)
        }
    }

    private func shutdown() {
        renderer = nil
        window = nil
    }

    private func handle(event: SDL_Event) throws -> Bool {
        switch event.eventType {
        case .quit, .windowCloseRequested:
            throw SelectionError.cancelled
        case .keyDown:
            return try handleKeyDown(event.key)
        case .mouseButtonDown:
            return try handleMouseButtonDown(event.button)
        default:
            return false
        }
    }

    private func handleKeyDown(_ event: SDL_KeyboardEvent) throws -> Bool {
        if event.repeat {
            return false
        }

        switch event.key {
        case SDLK_ESCAPE:
            throw SelectionError.cancelled
        case SDLK_A:
            openFolderDialog()
        case SDLK_DELETE, SDLK_BACKSPACE:
            removeSelectedPath()
        case SDLK_LEFTBRACKET:
            moveSelectedPath(by: -1)
        case SDLK_RIGHTBRACKET:
            moveSelectedPath(by: 1)
        case SDLK_UP:
            moveSelection(by: -1)
        case SDLK_DOWN:
            moveSelection(by: 1)
        case SDLK_RETURN, SDLK_RETURN2:
            return continueWithSelection()
        default:
            break
        }

        return false
    }

    private func handleMouseButtonDown(_ event: SDL_MouseButtonEvent) throws -> Bool {
        let windowSize = try currentWindowSize()
        guard event.button == SDL_BUTTON_LEFT else {
            return false
        }

        let position = event.position(as: Float.self)
        for button in buttons(for: windowSize) {
            if Self.contains(position: position, in: button.rect) {
                switch button.action {
                case .addFolders:
                    openFolderDialog()
                    return false
                case .removeSelected:
                    removeSelectedPath()
                    return false
                case .moveSelectedUp:
                    moveSelectedPath(by: -1)
                    return false
                case .moveSelectedDown:
                    moveSelectedPath(by: 1)
                    return false
                case .saveAndContinue:
                    return continueWithSelection()
                case .quit:
                    throw SelectionError.cancelled
                }
            }
        }

        if let index = listIndex(at: position, windowSize: windowSize) {
            selectedIndex = index
            ensureSelectionVisible(visibleRowCapacity: visibleRowCapacity(for: windowSize))
        }

        return false
    }

    private func processDialogResultIfNeeded() -> Bool {
        guard let result = dialogResultBox.take() else {
            return false
        }

        isFolderDialogOpen = false
        switch result {
        case .cancelled:
            statusMessage = "Folder selection cancelled."
            statusColor = Self.mutedTextColor
        case .failure(let message):
            statusMessage = message
            statusColor = Self.errorTextColor
        case .selected(let paths):
            appendDatapackPaths(paths)
        }
        return false
    }

    private func appendDatapackPaths(_ paths: [String]) {
        let existingPaths = Set(datapackPaths)
        let normalizedPaths = paths.map(Self.normalizedPath)
        let newPaths = normalizedPaths.filter { !existingPaths.contains($0) }

        guard !newPaths.isEmpty else {
            statusMessage = "All selected folders were already in the list."
            statusColor = Self.mutedTextColor
            return
        }

        datapackPaths.append(contentsOf: newPaths)
        selectedIndex = datapackPaths.count - 1
        ensureSelectionVisible(visibleRowCapacity: visibleRowCapacity(for: currentWindowSizeOrDefault()))
        statusMessage = "Added \(newPaths.count) datapack folder\(newPaths.count == 1 ? "" : "s")."
        statusColor = Self.successTextColor
    }

    private func moveSelection(by delta: Int) {
        guard !datapackPaths.isEmpty else {
            return
        }

        let currentIndex = selectedIndex ?? 0
        let nextIndex = max(0, min(datapackPaths.count - 1, currentIndex + delta))
        selectedIndex = nextIndex
        ensureSelectionVisible(visibleRowCapacity: visibleRowCapacity(for: currentWindowSizeOrDefault()))
    }

    private func moveSelectedPath(by delta: Int) {
        guard let selectedIndex else {
            statusMessage = "Select a datapack first."
            statusColor = Self.errorTextColor
            return
        }

        let destinationIndex = selectedIndex + delta
        guard datapackPaths.indices.contains(destinationIndex) else {
            return
        }

        datapackPaths.swapAt(selectedIndex, destinationIndex)
        self.selectedIndex = destinationIndex
        ensureSelectionVisible(visibleRowCapacity: visibleRowCapacity(for: currentWindowSizeOrDefault()))
        statusMessage = "Moved datapack \(delta < 0 ? "up" : "down")."
        statusColor = Self.successTextColor
    }

    private func removeSelectedPath() {
        guard let selectedIndex else {
            statusMessage = "Select a datapack first."
            statusColor = Self.errorTextColor
            return
        }

        let removedPath = datapackPaths.remove(at: selectedIndex)
        if datapackPaths.isEmpty {
            self.selectedIndex = nil
            listScrollOffset = 0
        } else {
            self.selectedIndex = min(selectedIndex, datapackPaths.count - 1)
        }
        ensureSelectionVisible(visibleRowCapacity: visibleRowCapacity(for: currentWindowSizeOrDefault()))
        statusMessage = "Removed \(removedPath)."
        statusColor = Self.successTextColor
    }

    private func continueWithSelection() -> Bool {
        guard !datapackPaths.isEmpty else {
            statusMessage = "Add at least one datapack before continuing."
            statusColor = Self.errorTextColor
            return false
        }

        let fileManager = FileManager.default
        for path in datapackPaths {
            var isDirectory = ObjCBool(false)
            if !fileManager.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                statusMessage = "Datapack folder not found: \(path)"
                statusColor = Self.errorTextColor
                return false
            }
        }

        return true
    }

    private func finalizedSelection() throws -> [URL] {
        guard continueWithSelection() else {
            throw SDL_Error.error
        }

        return datapackPaths.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
    }

    private func openFolderDialog() {
        guard !isFolderDialogOpen else {
            return
        }

        isFolderDialogOpen = true
        statusMessage = "Waiting for folder selection..."
        statusColor = Self.mutedTextColor

        guard let window else {
            isFolderDialogOpen = false
            statusMessage = "Folder picker window was unavailable."
            statusColor = Self.errorTextColor
            return
        }

        let defaultLocation = selectedIndex.flatMap { datapackPaths.indices.contains($0) ? datapackPaths[$0] : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        defaultLocation.withCString { defaultLocationPointer in
            SDL_ShowOpenFolderDialog(
                datapackFolderDialogCallback,
                Unmanaged.passUnretained(dialogResultBox).toOpaque(),
                window.pointer,
                defaultLocationPointer,
                true
            )
        }
    }

    private func render() throws {
        guard let window, let renderer else {
            throw SDL_Error.error
        }
        let windowSize = try window.pixelSize().to(Float.self)
        let listRect = listRect(for: windowSize)
        let buttons = buttons(for: windowSize)
        let rowHeight: Float = 42
        let visibleRows = visibleRowCapacity(for: windowSize)

        try renderer.clear(color: Self.backgroundColor)
        try renderer.fill(rects: [listRect], color: Self.panelColor)
        try drawBorder(for: listRect, color: Self.panelBorderColor)

        try renderer.debug(
            text: "Select datapack folders",
            position: [36, 20],
            color: Self.textColor,
            scale: [2.4, 2.4]
        )

        let instructionLines = [
            "The top entry is applied first.",
            "A or button: add folders. Delete: remove. [ and ]: move. Enter: save and continue.",
            "Arrow keys or click a row to change selection."
        ]
        for (index, line) in instructionLines.enumerated() {
            try renderer.debug(
                text: line,
                position: [36, 76 + Float(index) * 20],
                color: Self.mutedTextColor,
                scale: [1.05, 1.05]
            )
        }

        if datapackPaths.isEmpty {
            try renderer.debug(
                text: "No datapack folders selected yet.",
                position: [listRect.x + 18, listRect.y + 18],
                color: Self.mutedTextColor,
                scale: [1.15, 1.15]
            )
        } else {
            let maxCharacters = max(24, Int((listRect.w - 44) / String.debugFontSize(as: Float.self)))
            let visibleEndIndex = min(datapackPaths.count, listScrollOffset + visibleRows)
            for rowOffset in 0..<(visibleEndIndex - listScrollOffset) {
                let pathIndex = listScrollOffset + rowOffset
                let rowY = listRect.y + 12 + Float(rowOffset) * rowHeight
                let rowRect = SDL_FRect([listRect.x + 10, rowY, listRect.w - 20, rowHeight - 4])
                let isSelected = pathIndex == selectedIndex
                try renderer.fill(
                    rects: [rowRect],
                    color: isSelected ? Self.selectedRowColor : Self.rowColor
                )

                let prefix = "\(pathIndex + 1). "
                let text = prefix + Self.truncatedPath(datapackPaths[pathIndex], maxCharacters: maxCharacters - prefix.count)
                try renderer.debug(
                    text: text,
                    position: [rowRect.x + 10, rowRect.y + 12],
                    color: Self.textColor,
                    scale: [1.0, 1.0]
                )
            }
        }

        try renderer.debug(
            text: "Actions",
            position: [36, windowSize.y - 162],
            color: Self.mutedTextColor,
            scale: [1.05, 1.05]
        )

        for button in buttons {
            let isPrimaryAction = button.action == .saveAndContinue
            try renderer.fill(
                rects: [button.rect],
                color: isPrimaryAction ? Self.buttonActiveColor : Self.buttonColor
            )
            try drawBorder(for: button.rect, color: Self.panelBorderColor)
            try renderer.debug(
                text: button.title,
                position: [button.rect.x + 14, button.rect.y + 14],
                color: Self.textColor,
                scale: [1.0, 1.0]
            )
        }

        if datapackPaths.count > visibleRows {
            let scrollText = "Showing \(listScrollOffset + 1)-\(min(datapackPaths.count, listScrollOffset + visibleRows)) of \(datapackPaths.count)"
            try renderer.debug(
                text: scrollText,
                position: [listRect.x + 14, listRect.y + listRect.h - 24],
                color: Self.mutedTextColor,
                scale: [1.0, 1.0]
            )
        }

        let dialogText = isFolderDialogOpen ? "Native folder picker is open..." : statusMessage
        let dialogColor = isFolderDialogOpen ? Self.mutedTextColor : statusColor
        try renderer.debug(
            text: dialogText,
            position: [36, windowSize.y - 36],
            color: dialogColor,
            scale: [1.2, 1.2]
        )

        try renderer.present()
    }

    private func buttons(for windowSize: Size<Float>) -> [Button] {
        let horizontalMargin: Float = 36
        let bottomY = windowSize.y - 138
        let rowHeight: Float = 44
        let rowSpacing: Float = 14
        let buttonSpacing: Float = 12
        let titles: [(String, Action)] = [
            ("A: Add Folders", .addFolders),
            ("Del: Remove", .removeSelected),
            ("[: Move Up", .moveSelectedUp),
            ("]: Move Down", .moveSelectedDown),
            ("Enter: Continue", .saveAndContinue),
            ("Esc: Quit", .quit)
        ]

        let availableWidth = windowSize.x - horizontalMargin * 2 - buttonSpacing * 2
        let buttonWidth = max(120, availableWidth / 3)

        return titles.enumerated().map { index, titleAndAction in
            let row = Float(index / 3)
            let column = Float(index % 3)
            let x = horizontalMargin + column * (buttonWidth + buttonSpacing)
            let y = bottomY + row * (rowHeight + rowSpacing)
            return Button(
                title: titleAndAction.0,
                action: titleAndAction.1,
                rect: SDL_FRect([x, y, buttonWidth, rowHeight])
            )
        }
    }

    private func listRect(for windowSize: Size<Float>) -> SDL_FRect {
        SDL_FRect([36, 170, windowSize.x - 72, windowSize.y - 330])
    }

    private func visibleRowCapacity(for windowSize: Size<Float>) -> Int {
        max(1, Int((listRect(for: windowSize).h - 24) / 42))
    }

    private func listIndex(at point: Point<Float>, windowSize: Size<Float>) -> Int? {
        let listRect = listRect(for: windowSize)
        guard Self.contains(position: point, in: listRect) else {
            return nil
        }

        let rowHeight: Float = 42
        let rowOffset = Int((point.y - listRect.y - 12) / rowHeight)
        guard rowOffset >= 0 else {
            return nil
        }

        let pathIndex = listScrollOffset + rowOffset
        guard datapackPaths.indices.contains(pathIndex) else {
            return nil
        }
        return pathIndex
    }

    private func ensureSelectionVisible(visibleRowCapacity: Int) {
        guard let selectedIndex else {
            listScrollOffset = 0
            return
        }

        if selectedIndex < listScrollOffset {
            listScrollOffset = selectedIndex
        } else if selectedIndex >= listScrollOffset + visibleRowCapacity {
            listScrollOffset = selectedIndex - visibleRowCapacity + 1
        }

        listScrollOffset = max(0, min(listScrollOffset, max(0, datapackPaths.count - visibleRowCapacity)))
    }

    private func currentWindowSize() throws -> Size<Float> {
        guard let window else {
            throw SDL_Error.error
        }
        return try window.pixelSize().to(Float.self)
    }

    private func currentWindowSizeOrDefault() -> Size<Float> {
        (try? currentWindowSize()) ?? [1120, 760]
    }

    private func drawBorder(for rect: SDL_FRect, color: SDL_Color) throws {
        guard let renderer else {
            throw SDL_Error.error
        }
        let x = rect.x
        let y = rect.y
        let w = rect.w
        let h = rect.h
        let points: [SDL_FPoint] = [
            [x, y],
            [x + w, y],
            [x + w, y + h],
            [x, y + h],
            [x, y]
        ]
        try renderer.lines(points, color: color)
    }

    private static func contains(position: Point<Float>, in rect: SDL_FRect) -> Bool {
        position.x >= rect.x &&
        position.x <= rect.x + rect.w &&
        position.y >= rect.y &&
        position.y <= rect.y + rect.h
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(
            fileURLWithPath: NSString(string: path).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL.path
    }

    private static func truncatedPath(_ path: String, maxCharacters: Int) -> String {
        guard path.count > maxCharacters, maxCharacters > 5 else {
            return path
        }

        let visiblePrefixCount = max(2, (maxCharacters - 1) / 2)
        let visibleSuffixCount = max(2, maxCharacters - visiblePrefixCount - 1)
        let prefix = path.prefix(visiblePrefixCount)
        let suffix = path.suffix(visibleSuffixCount)
        return "\(prefix)...\(suffix)"
    }
}
