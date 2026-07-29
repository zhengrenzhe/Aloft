import Foundation

extension TerminalSurfaceFactory {
    static let swiftTerm = Self { _, callbacks in
        SwiftTermSurface(callbacks: callbacks)
    }
}
