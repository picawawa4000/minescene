import Foundation
#if canImport(simd)
import simd
#endif

extension TerrainRenderer {
    private struct HudTextRun {
        let text: String
        let color: SIMD4<Float>
    }

    private struct HudStyle {
        let cellSize: Float
        let glyphAdvance: Float
        let lineAdvance: Float
    }

    private enum HudAlignment {
        case left
        case right
    }

    func updateHudIfNeeded(engine: VulkanEngine, viewportWidth: Int, viewportHeight: Int) throws {
        let biomeText = currentBiomeHudText()
        let debugLines = currentDebugHudLines()
        let promptDisplayText = currentCommandPromptDisplayText()
        let promptCursorVisible = isCommandPromptCursorVisible()
        let commandLogSignature = currentCommandLogSignature()
        let positionRuns = [
            HudTextRun(text: String(format: "X: %.1f ", cameraPosition.x), color: hudXColor),
            HudTextRun(text: String(format: "Y: %.1f ", cameraPosition.y), color: hudYColor),
            HudTextRun(text: String(format: "Z: %.1f", cameraPosition.z), color: hudZColor)
        ]
        let fpsRuns = [
            HudTextRun(text: String(format: "FPS: %.0f", Double(smoothedFps)), color: hudFpsColor)
        ]
        let biomeRuns = [
            HudTextRun(text: biomeText, color: hudBiomeColor)
        ]
        let debugRuns = debugLines.map { [HudTextRun(text: $0, color: hudDebugColor)] }
        let hudText = ([positionRuns, fpsRuns, biomeRuns] + debugRuns)
            .flatMap { $0.map(\.text) }
            .joined(separator: "\n") + "\nprompt:\(promptDisplayText ?? ""):\(promptCursorVisible ? 1 : 0)\nlog:\(commandLogSignature)"
        let viewport = SIMD2<Int>(viewportWidth, viewportHeight)
        guard hudText != lastHudText || viewport != lastHudViewport || biomeText != lastHudBiome else {
            return
        }

        let vertices = makeHudVertices(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            leftLines: [positionRuns, fpsRuns],
            rightLines: [biomeRuns] + debugRuns,
            promptText: promptDisplayText,
            promptCursorVisible: promptCursorVisible
        )
        if vertices.isEmpty {
            hudVertexCount = 0
            lastHudText = hudText
            lastHudViewport = viewport
            lastHudBiome = biomeText
            return
        }

        if hudBuffer == nil || hudMemory == nil || vertices.count > hudVertexCapacity {
            hudBuffer = nil
            hudMemory = nil
            hudVertexCapacity = max(vertices.count, max(256, hudVertexCapacity * 2))
            let (buffer, memory) = try engine.createVertexBuffer2DCapacity(hudVertexCapacity)
            hudBuffer = buffer
            hudMemory = memory
        }

        guard let hudBuffer, let hudMemory else {
            return
        }

        hudVertexCount = try engine.updateVertexBuffer2D(
            vertices,
            buffer: hudBuffer,
            memory: hudMemory,
            capacity: hudVertexCapacity
        )
        lastHudText = hudText
        lastHudViewport = viewport
        lastHudBiome = biomeText
    }

    private func makeHudVertices(
        viewportWidth: Int,
        viewportHeight: Int,
        leftLines: [[HudTextRun]],
        rightLines: [[HudTextRun]],
        promptText: String?,
        promptCursorVisible: Bool
    ) -> [VulkanEngine.Vertex2D] {
        let standardStyle = HudStyle(cellSize: 5, glyphAdvance: 20, lineAdvance: 34)
        let compactStyle = HudStyle(cellSize: 3, glyphAdvance: 12, lineAdvance: 16)
        let shadowOffset = SIMD2<Float>(1, 1)
        let leftOrigin = SIMD2<Float>(12, 12)
        let rightMargin: Float = 12

        var vertices: [VulkanEngine.Vertex2D] = []
        let characterCount = (leftLines + rightLines).flatMap { $0 }.reduce(0) { $0 + $1.text.count } + (promptText?.count ?? 0)
        vertices.reserveCapacity(characterCount * 180 + (promptText == nil ? 0 : 512))

        appendHudLines(
            leftLines,
            originX: leftOrigin.x,
            originY: leftOrigin.y,
            viewportWidth: Float(viewportWidth),
            alignment: .left,
            style: standardStyle,
            shadowOffset: shadowOffset,
            into: &vertices
        )
        appendHudLines(
            rightLines,
            originX: Float(viewportWidth) - rightMargin,
            originY: leftOrigin.y,
            viewportWidth: Float(viewportWidth),
            alignment: .right,
            style: compactStyle,
            shadowOffset: shadowOffset,
            into: &vertices
        )
        if let promptText {
            appendCommandPrompt(
                text: promptText,
                cursorVisible: promptCursorVisible,
                viewportWidth: Float(viewportWidth),
                viewportHeight: Float(viewportHeight),
                into: &vertices
            )
        }
        if !commandLogEntries.isEmpty {
            appendCommandLog(
                viewportWidth: Float(viewportWidth),
                viewportHeight: Float(viewportHeight),
                into: &vertices
            )
        }

        return vertices
    }

    private func appendHudLines(
        _ lines: [[HudTextRun]],
        originX: Float,
        originY: Float,
        viewportWidth: Float,
        alignment: HudAlignment,
        style: HudStyle,
        shadowOffset: SIMD2<Float>,
        into vertices: inout [VulkanEngine.Vertex2D]
    ) {
        for (lineIndex, lineRuns) in lines.enumerated() {
            let lineWidth = hudLineWidth(lineRuns, glyphAdvance: style.glyphAdvance)
            let startX: Float
            switch alignment {
            case .left:
                startX = originX
            case .right:
                startX = max(0, min(originX - lineWidth, viewportWidth - lineWidth))
            }

            var cursorX = startX
            let lineY = originY + Float(lineIndex) * style.lineAdvance
            for run in lineRuns {
                for character in run.text {
                    let glyph = Self.hudGlyphs[character] ?? Self.hudGlyphs[" "]!
                    appendGlyph(
                        glyph,
                        origin: SIMD2<Float>(cursorX + shadowOffset.x, lineY + shadowOffset.y),
                        cellSize: style.cellSize,
                        color: hudShadowColor,
                        into: &vertices
                    )
                    appendGlyph(
                        glyph,
                        origin: SIMD2<Float>(cursorX, lineY),
                        cellSize: style.cellSize,
                        color: run.color,
                        into: &vertices
                    )
                    cursorX += style.glyphAdvance
                }
            }
        }
    }

    private func hudLineWidth(_ runs: [HudTextRun], glyphAdvance: Float) -> Float {
        Float(runs.reduce(0) { $0 + $1.text.count }) * glyphAdvance
    }

    private func currentBiomeHudText() -> String {
        let cameraBlock = SIMD3<Int>(
            Int(floor(cameraPosition.x)),
            Int(floor(cameraPosition.y)),
            Int(floor(cameraPosition.z))
        )
        let biomeName = streamer.currentBiomeName(at: cameraBlock) ?? "unknown"
        return "BIOME: \(formatBiomeName(biomeName))"
    }

    private func currentDebugHudLines() -> [String] {
        let status = streamer.debugStatus()
        var lines: [String] = []
        if let preparationStatus = currentCinematicPreparationStatus {
            lines.append(
                "CINEMATIC: \(preparationStatus.readyChunks)/\(preparationStatus.totalChunks) READY"
            )
            lines.append(
                "PREP: GEN \(preparationStatus.generatingChunks) MESH \(preparationStatus.meshingChunks)"
            )
        }
        lines.append(contentsOf: [
            "CHUNKS: \(status.generatedChunks)/\(status.totalTargetChunks)",
            "GEN: \(status.inFlightGenerationChunks) MESH: \(status.inFlightMeshChunks)",
            "DIRTY: \(status.dirtyMeshChunks) DRAWN: \(chunkMeshes.count)"
        ])
        return lines
    }

    private func formatBiomeName(_ biomeName: String) -> String {
        let trimmedNamespace: Substring
        if let colonIndex = biomeName.lastIndex(of: ":") {
            trimmedNamespace = biomeName[biomeName.index(after: colonIndex)...]
        } else {
            trimmedNamespace = Substring(biomeName)
        }

        return trimmedNamespace
            .split(separator: "_")
            .map { token in
                guard let first = token.first else { return "" }
                return String(first).uppercased() + token.dropFirst().lowercased()
            }
            .joined(separator: " ")
            .uppercased()
    }

    private func appendCommandLog(
        viewportWidth: Float,
        viewportHeight: Float,
        into vertices: inout [VulkanEngine.Vertex2D]
    ) {
        let cellSize: Float = 2
        let glyphAdvance: Float = 14
        let promptBarHeight: Float = 38
        let logLineHeight: Float = 18
        let logVerticalPadding: Float = 10
        let logSpacing: Float = 4
        let selectedHistoryIndex = commandPromptActive ? commandPromptHistoryIndex : nil
        let visibleEntries = visibleCommandLogEntries().reversed()
        let maxColumns = max(1, Int(floor((viewportWidth - 24) / glyphAdvance)))
        var nextLineBottom = viewportHeight - promptBarHeight

        for entry in visibleEntries {
            let fade: Float
            if commandPromptActive {
                fade = 1
            } else {
                let fadeProgress = max(0, entry.age - commandLogHoldDuration) / commandLogFadeDuration
                fade = max(0, 1 - fadeProgress)
            }
            guard fade > 0 else {
                continue
            }

            let wrappedLines = wrapCommandLogText(entry.message, maxColumns: maxColumns)
            let logBarHeight = logVerticalPadding + Float(wrappedLines.count) * logLineHeight
            let lineBottom = nextLineBottom
            let lineTop = lineBottom - logBarHeight
            let isSelected = selectedHistoryIndex != nil && entry.commandHistoryIndex == selectedHistoryIndex
            let backgroundBaseColor = isSelected
                ? commandLogSelectedBackgroundColor
                : commandLogBackgroundColor
            let backgroundColor = SIMD4<Float>(
                backgroundBaseColor.x,
                backgroundBaseColor.y,
                backgroundBaseColor.z,
                backgroundBaseColor.w * fade
            )
            let baseTextColor = entry.isError ? commandLogErrorColor : commandPromptTextColor
            let textColor = SIMD4<Float>(
                baseTextColor.x,
                baseTextColor.y,
                baseTextColor.z,
                fade
            )

            appendHudQuad(
                minX: 0,
                minY: lineTop,
                maxX: viewportWidth,
                maxY: lineBottom,
                color: backgroundColor,
                into: &vertices
            )
            for (lineIndex, line) in wrappedLines.enumerated() {
                appendPromptFontText(
                    line,
                    origin: SIMD2<Float>(12, lineTop + 6 + Float(lineIndex) * logLineHeight),
                    cellSize: cellSize,
                    glyphAdvance: glyphAdvance,
                    color: textColor,
                    into: &vertices
                )
            }
            nextLineBottom = lineTop - logSpacing
        }
    }

    private func visibleCommandLogEntries() -> ArraySlice<TerrainRendererCommandLogEntry> {
        let visibleLimit = commandPromptActive ? commandPromptLogVisibleEntryLimit : commandLogVisibleEntryLimit
        guard commandLogEntries.count > visibleLimit else {
            return commandLogEntries[...]
        }
        let clampedOffset = min(commandLogScrollOffset, max(0, commandLogEntries.count - visibleLimit))
        let upperBound = commandLogEntries.count - clampedOffset
        let lowerBound = max(0, upperBound - visibleLimit)
        return commandLogEntries[lowerBound..<upperBound]
    }

    private func currentCommandLogSignature() -> String {
        let visibleEntries = visibleCommandLogEntries()
        let selectedHistoryIndex = commandPromptActive ? commandPromptHistoryIndex : nil
        return visibleEntries.enumerated().map { index, entry in
            let fade: Float
            if commandPromptActive {
                fade = 1
            } else {
                let fadeProgress = max(0, entry.age - commandLogHoldDuration) / commandLogFadeDuration
                fade = max(0, 1 - fadeProgress)
            }
            let isSelected = selectedHistoryIndex != nil && selectedHistoryIndex == entry.commandHistoryIndex
            return [
                String(index),
                entry.isError ? "error" : "info",
                entry.commandHistoryIndex.map(String.init) ?? "nil",
                isSelected ? "selected" : "plain",
                String(format: "%.3f", fade),
                entry.message
            ].joined(separator: ":")
        }.joined(separator: "|")
        + "#scroll:\(commandLogScrollOffset)"
        + "#count:\(commandLogEntries.count)"
    }

    private func wrapCommandLogText(_ text: String, maxColumns: Int) -> [String] {
        guard maxColumns > 0 else {
            return [text]
        }

        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let paragraphText = String(paragraph)
            if paragraphText.isEmpty {
                lines.append("")
                continue
            }

            var currentLine = ""
            for word in paragraphText.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
                if currentLine.isEmpty {
                    if word.count <= maxColumns {
                        currentLine = word
                    } else {
                        lines.append(contentsOf: wrapLongCommandWord(word, maxColumns: maxColumns))
                    }
                    continue
                }

                let candidate = "\(currentLine) \(word)"
                if candidate.count <= maxColumns {
                    currentLine = candidate
                } else {
                    lines.append(currentLine)
                    if word.count <= maxColumns {
                        currentLine = word
                    } else {
                        lines.append(contentsOf: wrapLongCommandWord(word, maxColumns: maxColumns))
                        currentLine = ""
                    }
                }
            }

            if !currentLine.isEmpty {
                lines.append(currentLine)
            }
        }

        return lines.isEmpty ? [""] : lines
    }

    private func wrapLongCommandWord(_ word: String, maxColumns: Int) -> [String] {
        var lines: [String] = []
        var startIndex = word.startIndex
        while startIndex < word.endIndex {
            let endIndex = word.index(startIndex, offsetBy: maxColumns, limitedBy: word.endIndex) ?? word.endIndex
            lines.append(String(word[startIndex..<endIndex]))
            startIndex = endIndex
        }
        return lines
    }

    private func appendCommandPrompt(
        text: String,
        cursorVisible: Bool,
        viewportWidth: Float,
        viewportHeight: Float,
        into vertices: inout [VulkanEngine.Vertex2D]
    ) {
        let cellSize: Float = 2
        let glyphAdvance: Float = 14
        let barHeight: Float = 38
        let textOrigin = SIMD2<Float>(12, viewportHeight - barHeight + 10)

        appendHudQuad(
            minX: 0,
            minY: viewportHeight - barHeight,
            maxX: viewportWidth,
            maxY: viewportHeight,
            color: commandPromptBackgroundColor,
            into: &vertices
        )

        var cursorX = textOrigin.x
        let slashGlyph = Self.promptGlyphs["/"] ?? Self.promptGlyphs[" "]!
        appendGlyph(
            slashGlyph,
            origin: SIMD2<Float>(cursorX, textOrigin.y),
            cellSize: cellSize,
            color: commandPromptTextColor,
            into: &vertices
        )
        cursorX += glyphAdvance

        appendPromptFontText(
            text,
            origin: SIMD2<Float>(cursorX, textOrigin.y),
            cellSize: cellSize,
            glyphAdvance: glyphAdvance,
            color: commandPromptTextColor,
            into: &vertices
        )
        cursorX += Float(text.count) * glyphAdvance

        if cursorVisible, let cursorGlyph = Self.promptGlyphs["_"] {
            appendGlyph(
                cursorGlyph,
                origin: SIMD2<Float>(cursorX, textOrigin.y),
                cellSize: cellSize,
                color: commandPromptCursorColor,
                into: &vertices
            )
        }
    }

    private func appendPromptFontText(
        _ text: String,
        origin: SIMD2<Float>,
        cellSize: Float,
        glyphAdvance: Float,
        color: SIMD4<Float>,
        into vertices: inout [VulkanEngine.Vertex2D]
    ) {
        var cursorX = origin.x
        for character in text {
            let glyph = Self.promptGlyphs[character] ?? Self.promptGlyphs[" "]!
            appendGlyph(
                glyph,
                origin: SIMD2<Float>(cursorX, origin.y),
                cellSize: cellSize,
                color: color,
                into: &vertices
            )
            cursorX += glyphAdvance
        }
    }

    private func appendGlyph(
        _ glyph: [String],
        origin: SIMD2<Float>,
        cellSize: Float,
        color: SIMD4<Float>,
        into vertices: inout [VulkanEngine.Vertex2D]
    ) {
        for (rowIndex, row) in glyph.enumerated() {
            for (columnIndex, pixel) in row.enumerated() where pixel != "0" {
                let minX = origin.x + Float(columnIndex) * cellSize
                let minY = origin.y + Float(rowIndex) * cellSize
                appendHudQuad(
                    minX: minX,
                    minY: minY,
                    maxX: minX + cellSize,
                    maxY: minY + cellSize,
                    color: color,
                    into: &vertices
                )
            }
        }
    }

    private func appendHudQuad(
        minX: Float,
        minY: Float,
        maxX: Float,
        maxY: Float,
        color: SIMD4<Float>,
        into vertices: inout [VulkanEngine.Vertex2D]
    ) {
        let p0 = SIMD2<Float>(minX, minY)
        let p1 = SIMD2<Float>(maxX, minY)
        let p2 = SIMD2<Float>(maxX, maxY)
        let p3 = SIMD2<Float>(minX, maxY)
        vertices.append(.init(position: p0, color: color))
        vertices.append(.init(position: p1, color: color))
        vertices.append(.init(position: p2, color: color))
        vertices.append(.init(position: p0, color: color))
        vertices.append(.init(position: p2, color: color))
        vertices.append(.init(position: p3, color: color))
    }

    func hudTransform(width: Float, height: Float) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(2 / width, 0, 0, 0),
            SIMD4<Float>(0, 2 / height, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-1, -1, 0, 1)
        )
    }

    private static let promptGlyphs: [Character: [String]] = [
        "0": ["0111110", "1100011", "1100111", "1101111", "1111011", "1110011", "1100011", "0111110", "0000000"],
        "1": ["0011000", "0111000", "0011000", "0011000", "0011000", "0011000", "0011000", "1111111", "0000000"],
        "2": ["0111110", "1100011", "0000011", "0000110", "0001100", "0110000", "1100000", "1111111", "0000000"],
        "3": ["0111110", "1100011", "0000011", "0011110", "0000011", "0000011", "1100011", "0111110", "0000000"],
        "4": ["0001110", "0011110", "0110110", "1100110", "1111111", "0000110", "0000110", "0001111", "0000000"],
        "5": ["1111111", "1100000", "1100000", "1111110", "0000011", "0000011", "1100011", "0111110", "0000000"],
        "6": ["0011110", "0110000", "1100000", "1111110", "1100011", "1100011", "1100011", "0111110", "0000000"],
        "7": ["1111111", "0000011", "0000110", "0001100", "0011000", "0011000", "0011000", "0011000", "0000000"],
        "8": ["0111110", "1100011", "1100011", "0111110", "1100011", "1100011", "1100011", "0111110", "0000000"],
        "9": ["0111110", "1100011", "1100011", "1100011", "0111111", "0000011", "0000110", "0111100", "0000000"],

        "A": ["0011100", "0110110", "1100011", "1100011", "1111111", "1100011", "1100011", "1100011", "0000000"],
        "B": ["1111110", "1100011", "1100011", "1111110", "1100011", "1100011", "1100011", "1111110", "0000000"],
        "C": ["0111110", "1100011", "1100000", "1100000", "1100000", "1100000", "1100011", "0111110", "0000000"],
        "D": ["1111100", "1100110", "1100011", "1100011", "1100011", "1100011", "1100110", "1111100", "0000000"],
        "E": ["1111111", "1100000", "1100000", "1111110", "1100000", "1100000", "1100000", "1111111", "0000000"],
        "F": ["1111111", "1100000", "1100000", "1111110", "1100000", "1100000", "1100000", "1100000", "0000000"],
        "G": ["0111110", "1100011", "1100000", "1100000", "1101111", "1100011", "1100011", "0111110", "0000000"],
        "H": ["1100011", "1100011", "1100011", "1111111", "1100011", "1100011", "1100011", "1100011", "0000000"],
        "I": ["0111110", "0011000", "0011000", "0011000", "0011000", "0011000", "0011000", "0111110", "0000000"],
        "J": ["0001111", "0000110", "0000110", "0000110", "0000110", "1100110", "1100110", "0111100", "0000000"],
        "K": ["1100011", "1100110", "1101100", "1111000", "1111000", "1101100", "1100110", "1100011", "0000000"],
        "L": ["1100000", "1100000", "1100000", "1100000", "1100000", "1100000", "1100000", "1111111", "0000000"],
        "M": ["1100011", "1110111", "1111111", "1101011", "1100011", "1100011", "1100011", "1100011", "0000000"],
        "N": ["1100011", "1110011", "1111011", "1101111", "1100111", "1100011", "1100011", "1100011", "0000000"],
        "O": ["0111110", "1100011", "1100011", "1100011", "1100011", "1100011", "1100011", "0111110", "0000000"],
        "P": ["1111110", "1100011", "1100011", "1111110", "1100000", "1100000", "1100000", "1100000", "0000000"],
        "Q": ["0111110", "1100011", "1100011", "1100011", "1100011", "1101011", "1100110", "0111101", "0000000"],
        "R": ["1111110", "1100011", "1100011", "1111110", "1101100", "1100110", "1100011", "1100011", "0000000"],
        "S": ["0111110", "1100011", "1100000", "0111110", "0000011", "0000011", "1100011", "0111110", "0000000"],
        "T": ["1111111", "0011000", "0011000", "0011000", "0011000", "0011000", "0011000", "0011000", "0000000"],
        "U": ["1100011", "1100011", "1100011", "1100011", "1100011", "1100011", "1100011", "0111110", "0000000"],
        "V": ["1100011", "1100011", "1100011", "1100011", "1100011", "1100011", "0110110", "0011100", "0000000"],
        "W": ["1100011", "1100011", "1100011", "1100011", "1101011", "1111111", "1110111", "1100011", "0000000"],
        "X": ["1100011", "1100011", "0110110", "0011100", "0011100", "0110110", "1100011", "1100011", "0000000"],
        "Y": ["1100011", "1100011", "0110110", "0011100", "0011000", "0011000", "0011000", "0011000", "0000000"],
        "Z": ["1111111", "0000011", "0000110", "0001100", "0011000", "0110000", "1100000", "1111111", "0000000"],

        "a": ["0000000", "0000000", "0111110", "0000011", "0111111", "1100011", "1100011", "0111111", "0000000"],
        "b": ["1100000", "1100000", "1100000", "1111110", "1100011", "1100011", "1100011", "1111110", "0000000"],
        "c": ["0000000", "0000000", "0111110", "1100011", "1100000", "1100000", "1100011", "0111110", "0000000"],
        "d": ["0000011", "0000011", "0000011", "0111111", "1100011", "1100011", "1100011", "0111111", "0000000"],
        "e": ["0000000", "0000000", "0111110", "1100011", "1111111", "1100000", "1100011", "0111110", "0000000"],
        "f": ["0001110", "0011011", "0011000", "1111110", "0011000", "0011000", "0011000", "0011000", "0000000"],
        "g": ["0000000", "0000000", "0111111", "1100011", "1100011", "0111111", "0000011", "1100011", "0111110"],
        "h": ["1100000", "1100000", "1100000", "1111110", "1100011", "1100011", "1100011", "1100011", "0000000"],
        "i": ["0011000", "0000000", "0111000", "0011000", "0011000", "0011000", "0011000", "0111110", "0000000"],
        "j": ["0001100", "0000000", "0011100", "0001100", "0001100", "0001100", "0001100", "1101100", "0111000"],
        "k": ["1100000", "1100000", "1100011", "1100110", "1111100", "1100110", "1100011", "1100011", "0000000"],
        "l": ["0111000", "0011000", "0011000", "0011000", "0011000", "0011000", "0011000", "0111110", "0000000"],
        "m": ["0000000", "0000000", "1110110", "1111111", "1101011", "1101011", "1100011", "1100011", "0000000"],
        "n": ["0000000", "0000000", "1111110", "1100011", "1100011", "1100011", "1100011", "1100011", "0000000"],
        "o": ["0000000", "0000000", "0111110", "1100011", "1100011", "1100011", "1100011", "0111110", "0000000"],
        "p": ["0000000", "0000000", "1111110", "1100011", "1100011", "1111110", "1100000", "1100000", "1100000"],
        "q": ["0000000", "0000000", "0111111", "1100011", "1100011", "0111111", "0000011", "0000011", "0000011"],
        "r": ["0000000", "0000000", "1101110", "1110011", "1100000", "1100000", "1100000", "1100000", "0000000"],
        "s": ["0000000", "0000000", "0111111", "1100000", "0111110", "0000011", "1100011", "0111110", "0000000"],
        "t": ["0011000", "0011000", "1111110", "0011000", "0011000", "0011000", "0011011", "0001110", "0000000"],
        "u": ["0000000", "0000000", "1100011", "1100011", "1100011", "1100011", "1100111", "0111011", "0000000"],
        "v": ["0000000", "0000000", "1100011", "1100011", "1100011", "1100011", "0110110", "0011100", "0000000"],
        "w": ["0000000", "0000000", "1100011", "1100011", "1101011", "1101011", "1111111", "0110110", "0000000"],
        "x": ["0000000", "0000000", "1100011", "0110110", "0011100", "0011100", "0110110", "1100011", "0000000"],
        "y": ["0000000", "0000000", "1100011", "1100011", "1100011", "0111111", "0000011", "1100011", "0111110"],
        "z": ["0000000", "0000000", "1111111", "0000110", "0001100", "0011000", "0110000", "1111111", "0000000"],

        " ": ["0000000", "0000000", "0000000", "0000000", "0000000", "0000000", "0000000", "0000000", "0000000"],
        "/": ["0000011", "0000110", "0001100", "0011000", "0110000", "1100000", "0000000", "0000000", "0000000"],
        "\\": ["1100000", "0110000", "0011000", "0001100", "0000110", "0000011", "0000000", "0000000", "0000000"],
        "_": ["0000000", "0000000", "0000000", "0000000", "0000000", "0000000", "0000000", "0000000", "1111111"],
        "-": ["0000000", "0000000", "0000000", "0111110", "0111110", "0000000", "0000000", "0000000", "0000000"],
        ".": ["0000000", "0000000", "0000000", "0000000", "0000000", "0000000", "0000000", "0011000", "0011000"],
        ",": ["0000000", "0000000", "0000000", "0000000", "0000000", "0000000", "0011000", "0011000", "0110000"],
        ":": ["0000000", "0011000", "0011000", "0000000", "0000000", "0011000", "0011000", "0000000", "0000000"],
        ";": ["0000000", "0011000", "0011000", "0000000", "0000000", "0011000", "0011000", "0110000", "0000000"],
        "=": ["0000000", "0000000", "1111111", "0000000", "1111111", "0000000", "0000000", "0000000", "0000000"],
        "+": ["0000000", "0011000", "0011000", "1111111", "0011000", "0011000", "0000000", "0000000", "0000000"],
        "*": ["0000000", "1100011", "0110110", "0011100", "0110110", "1100011", "0000000", "0000000", "0000000"],
        "#": ["0000000", "0110110", "1111111", "0110110", "0110110", "1111111", "0110110", "0000000", "0000000"],
        "@": ["0011110", "0110011", "1101111", "1101011", "1101111", "1100000", "0111110", "0000000", "0000000"],
        "~": ["0000000", "0000000", "0110010", "1001101", "0000000", "0000000", "0000000", "0000000", "0000000"],
        "^": ["0011000", "0110110", "1100011", "0000000", "0000000", "0000000", "0000000", "0000000", "0000000"],
        "!": ["0011000", "0011000", "0011000", "0011000", "0011000", "0000000", "0011000", "0011000", "0000000"],
        "?": ["0111110", "1100011", "0000011", "0001110", "0011000", "0000000", "0011000", "0011000", "0000000"],
        "'": ["0011000", "0011000", "0001100", "0000000", "0000000", "0000000", "0000000", "0000000", "0000000"],
        "\"": ["0110110", "0110110", "0010010", "0000000", "0000000", "0000000", "0000000", "0000000", "0000000"],
        "[": ["0011110", "0011000", "0011000", "0011000", "0011000", "0011000", "0011000", "0011110", "0000000"],
        "]": ["0111100", "0001100", "0001100", "0001100", "0001100", "0001100", "0001100", "0111100", "0000000"],
        "{": ["0001110", "0011000", "0011000", "1110000", "0011000", "0011000", "0011000", "0001110", "0000000"],
        "}": ["1110000", "0001100", "0001100", "0000111", "0001100", "0001100", "0001100", "1110000", "0000000"],
        "(": ["0001110", "0011000", "0110000", "0110000", "0110000", "0110000", "0011000", "0001110", "0000000"],
        ")": ["0111000", "0001100", "0000110", "0000110", "0000110", "0000110", "0001100", "0111000", "0000000"],
        "<": ["0000110", "0001100", "0011000", "0110000", "0011000", "0001100", "0000110", "0000000", "0000000"],
        ">": ["0110000", "0011000", "0001100", "0000110", "0001100", "0011000", "0110000", "0000000", "0000000"],
        "|": ["0011000", "0011000", "0011000", "0011000", "0011000", "0011000", "0011000", "0011000", "0000000"],
        "%": ["1100011", "1100110", "0001100", "0011000", "0110000", "1100110", "1000011", "0000000", "0000000"],
        "&": ["0011100", "0110110", "0111100", "0011000", "0111011", "1100110", "1100110", "0111011", "0000000"]
    ]

    private static let hudGlyphs: [Character: [String]] = [
        "0": ["111", "101", "101", "101", "111"],
        "1": ["010", "110", "010", "010", "111"],
        "2": ["111", "001", "111", "100", "111"],
        "3": ["111", "001", "111", "001", "111"],
        "4": ["101", "101", "111", "001", "001"],
        "5": ["111", "100", "111", "001", "111"],
        "6": ["111", "100", "111", "101", "111"],
        "7": ["111", "001", "001", "001", "001"],
        "8": ["111", "101", "111", "101", "111"],
        "9": ["111", "101", "111", "001", "111"],
        "A": ["010", "101", "111", "101", "101"],
        "B": ["110", "101", "110", "101", "110"],
        "C": ["011", "100", "100", "100", "011"],
        "D": ["110", "101", "101", "101", "110"],
        "E": ["111", "100", "110", "100", "111"],
        "F": ["111", "100", "110", "100", "100"],
        "G": ["011", "100", "101", "101", "011"],
        "H": ["101", "101", "111", "101", "101"],
        "I": ["111", "010", "010", "010", "111"],
        "J": ["001", "001", "001", "101", "010"],
        "K": ["101", "101", "110", "101", "101"],
        "L": ["100", "100", "100", "100", "111"],
        "M": ["101", "111", "111", "101", "101"],
        "N": ["101", "111", "111", "111", "101"],
        "O": ["010", "101", "101", "101", "010"],
        "P": ["110", "101", "110", "100", "100"],
        "Q": ["010", "101", "101", "111", "011"],
        "R": ["110", "101", "110", "101", "101"],
        "S": ["111", "100", "111", "001", "111"],
        "T": ["111", "010", "010", "010", "010"],
        "U": ["101", "101", "101", "101", "111"],
        "V": ["101", "101", "101", "101", "010"],
        "W": ["101", "101", "111", "111", "101"],
        "X": ["101", "101", "010", "101", "101"],
        "Y": ["101", "101", "010", "010", "010"],
        "Z": ["111", "001", "010", "100", "111"],
        "a": ["000", "011", "101", "111", "101"],
        "b": ["100", "110", "101", "110", "101"],
        "c": ["000", "011", "100", "100", "011"],
        "d": ["001", "011", "101", "101", "011"],
        "e": ["000", "011", "111", "100", "011"],
        "f": ["001", "010", "111", "010", "010"],
        "g": ["000", "011", "101", "011", "001"],
        "h": ["100", "110", "101", "101", "101"],
        "i": ["010", "000", "110", "010", "111"],
        "j": ["001", "000", "001", "101", "010"],
        "k": ["100", "101", "110", "101", "101"],
        "l": ["110", "010", "010", "010", "111"],
        "m": ["000", "111", "111", "101", "101"],
        "n": ["000", "110", "101", "101", "101"],
        "o": ["000", "010", "101", "101", "010"],
        "p": ["000", "110", "101", "110", "100"],
        "q": ["000", "011", "101", "011", "001"],
        "r": ["000", "101", "110", "100", "100"],
        "s": ["000", "011", "110", "011", "110"],
        "t": ["010", "111", "010", "010", "001"],
        "u": ["000", "101", "101", "101", "011"],
        "v": ["000", "101", "101", "101", "010"],
        "w": ["000", "101", "111", "111", "101"],
        "x": ["000", "101", "010", "010", "101"],
        "y": ["000", "101", "101", "011", "001"],
        "z": ["000", "111", "001", "010", "111"],
        "/": ["001", "001", "010", "100", "100"],
        ":": ["000", "010", "000", "010", "000"],
        ".": ["000", "000", "000", "000", "010"],
        ",": ["000", "000", "000", "010", "100"],
        "-": ["000", "000", "111", "000", "000"],
        "_": ["000", "000", "000", "000", "111"],
        "=": ["000", "111", "000", "111", "000"],
        "[": ["110", "100", "100", "100", "110"],
        "]": ["011", "001", "001", "001", "011"],
        "@": ["111", "101", "111", "100", "011"],
        "~": ["000", "101", "010", "000", "000"],
        "^": ["010", "101", "000", "000", "000"],
        "!": ["010", "010", "010", "000", "010"],
        "?": ["111", "001", "010", "000", "010"],
        "'": ["010", "010", "000", "000", "000"],
        "\"": ["101", "101", "000", "000", "000"],
        " ": ["000", "000", "000", "000", "000"]
    ]
}
