import Foundation

struct TerminalSize: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let pixelWidth: Int
    let pixelHeight: Int

    init?(
        columns: Int,
        rows: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        guard (1...Int(UInt16.max)).contains(columns),
              (1...Int(UInt16.max)).contains(rows),
              (0...Int(UInt16.max)).contains(pixelWidth),
              (0...Int(UInt16.max)).contains(pixelHeight) else {
            return nil
        }
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

enum TerminalRendererState: Equatable, Sendable {
    case awaitingWindow
    case metal
    case coreGraphicsFallback(String)
    case unavailable(String)
}

struct TerminalSurfaceCallbacks: Sendable {
    let writeProtocolReply: @Sendable (Data, UUID) -> Void
    let resizePTY: @Sendable (TerminalSize, UUID) -> Void
}
